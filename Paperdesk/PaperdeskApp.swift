import SwiftUI
import UniformTypeIdentifiers

@main struct PaperdeskApp: App {
    @State private var store = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LibraryView(store: store)
                .tint(PaperdeskPalette.teal)
                .task { await store.loadIfNeeded() }
                .onChange(of: scenePhase) { _, phase in if phase != .active { store.flushPendingChanges() } }
                #if os(macOS)
                    .onReceive(
                        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
                    ) { _ in store.flushPendingChanges() }
                #endif
                #if os(macOS)
                    .frame(minWidth: 850, minHeight: 600)
                #endif
        }
    }
}

struct LibraryView: View {
    @Bindable var store: LibraryStore
    @State private var selected: UUID?
    @State private var compactColumn = NavigationSplitViewColumn.detail
    @State private var importing = false
    @State private var importingPDF = false
    @State private var backup = false
    @State private var showingHelp = false
    @State private var filter = ""
    @State private var selectedFolder = LibraryFilter.all
    @State private var alphabetical = false
    @State private var renameTarget: LibraryDocument?
    @State private var renameText = ""
    @State private var moveTarget: LibraryDocument?
    @State private var folderText = ""
    @State private var deleteTarget: LibraryDocument?
    @State private var recovery = false

    @State private var folders: [String] = []
    @State private var visibleDocuments: [LibraryDocument] = []

    private func refreshDocuments() {
        folders = Array(Set(store.documents.compactMap(\.folder))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        if case .collection(let name) = selectedFolder, !folders.contains(name) {
            selectedFolder = .all
        }
        let matches = store.documents.filter { document in
            selectedFolder.includes(document)
                && (filter.isEmpty || document.title.localizedCaseInsensitiveContains(filter)
                    || document.notes.localizedCaseInsensitiveContains(filter))
        }
        visibleDocuments =
            alphabetical
            ? matches.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            : matches.sorted { $0.importedAt > $1.importedAt }
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            VStack(spacing: 0) {
                HStack {
                    Picker("Collection", selection: $selectedFolder) {
                        Text("All documents").tag(LibraryFilter.all)
                        Text("Unfiled").tag(LibraryFilter.unfiled)
                        ForEach(folders, id: \.self) { Text($0).tag(LibraryFilter.collection($0)) }
                    }.labelsHidden().pickerStyle(.menu)
                    Spacer(minLength: 4)
                    Menu {
                        Picker("Sort documents", selection: $alphabetical) {
                            Text("Recently imported").tag(false)
                            Text("Title").tag(true)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .help("Sort documents").accessibilityLabel("Sort documents")
                }.padding(.horizontal, 12).padding(.vertical, 8)
                Button {
                    selected = nil
                    compactColumn = .detail
                } label: {
                    Label("Library overview", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(12)
                Divider()
                List(selection: $selected) {
                    Section("\(visibleDocuments.count) document\(visibleDocuments.count == 1 ? "" : "s")") {
                        ForEach(visibleDocuments) { document in
                            documentRow(document)
                                .tag(document.id)
                                .contextMenu { documentActions(document) }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        deleteTarget = document
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        renameTarget = document
                                        renameText = document.title
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }.tint(.teal)
                                }
                        }
                    }
                }
                .overlay {
                    if store.isLoading {
                        ProgressView("Opening your library…")
                    } else if visibleDocuments.isEmpty {
                        VStack(spacing: 12) {
                            Text(
                                store.documents.isEmpty
                                    ? "Your documents will appear here." : "No matching documents."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            if store.documents.isEmpty {
                                Button("Explore a sample", systemImage: "book") { importSample() }
                                    .paperdeskActions()
                                    .disabled(importingPDF)
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .background { PaperdeskBackdrop() }
            .searchable(text: $filter, prompt: "Search titles and notes")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .navigationTitle("Paperdesk")
            .toolbar {
                Menu {
                    Button("About, Privacy & Help", systemImage: "questionmark.circle") { showingHelp = true }
                    Button("Library backup", systemImage: "externaldrive") { backup = true }
                    Button("Recover removed documents", systemImage: "clock.arrow.circlepath") { recovery = true }
                } label: {
                    Label("Library options", systemImage: "ellipsis.circle")
                }
                if selected != nil {
                    Button {
                        importing = true
                    } label: {
                        Label("Import PDF", systemImage: "plus")
                    }
                    .keyboardShortcut("o", modifiers: .command)
                    .help("Copy a PDF into your library").disabled(importingPDF || store.isLoading)
                }
            }
        } detail: {
            if let item = store.documents.first(where: { $0.id == selected }) {
                ReaderView(store: store, item: item).id(item.id)
            } else {
                LibraryOverview(
                    documents: visibleDocuments, directory: store.directory,
                    title: selectedFolder.title,
                    libraryIsEmpty: store.documents.isEmpty, importing: importingPDF,
                    onSelect: { selected = $0 }, onImport: { importing = true },
                    onSample: importSample,
                    documentActions: { document in documentActions(document) }
                )
            }
        }
        .disabled(store.isLoading)
        .sheet(isPresented: $showingHelp) { PaperdeskHelpView() }
        .sheet(isPresented: $backup) { BackupView(store: store) }
        .sheet(isPresented: $recovery) { DocumentHistoryView(store: store, documentID: nil) { selected = $0 } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) {
            result in
            let folder = selectedFolder
            importingPDF = true
            Task {
                defer { importingPDF = false }
                do {
                    for url in try result.get() {
                        let id = try await store.importPDFAsync(url)
                        if case .collection(let name) = folder { store.move(id, folder: name) }
                        selected = id
                    }
                } catch { store.error = error.localizedDescription }
            }
        }
        .safeAreaInset(edge: .bottom) { if importingPDF { ProgressView("Importing PDF…").padding(8) } }
        .alert(
            "Rename document",
            isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
        ) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let target = renameTarget { store.rename(target.id, title: renameText) }
                renameTarget = nil
            }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "Move to collection",
            isPresented: Binding(get: { moveTarget != nil }, set: { if !$0 { moveTarget = nil } })
        ) {
            TextField("Collection name", text: $folderText)
            Button("Cancel", role: .cancel) { moveTarget = nil }
            Button("Move") {
                if let target = moveTarget { store.move(target.id, folder: folderText) }
                moveTarget = nil
            }.disabled(folderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter an existing name or create a new collection.")
        }
        .confirmationDialog(
            "Delete document?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete from library", role: .destructive) {
                guard let target = deleteTarget else { return }
                do {
                    try store.remove(target.id)
                    if selected == target.id { selected = nil }
                } catch { store.error = error.localizedDescription }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(
                "This removes the document from the library. A recovery copy is kept locally, and your original imported file stays where it was."
            )
        }
        .alert(
            "Paperdesk",
            isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
        ) {
            Button("OK") { store.error = nil }
            Button("Retry loading library") { Task { await store.retryLoading() } }
        } message: {
            Text(store.error ?? "")
        }
        .onAppear { refreshDocuments() }
        .onChange(of: store.documents) { _, _ in refreshDocuments() }
        .onChange(of: selectedFolder) { _, _ in refreshDocuments() }
        .onChange(of: filter) { _, _ in refreshDocuments() }
        .onChange(of: alphabetical) { _, _ in refreshDocuments() }
    }

    private func importSample() {
        guard !importingPDF else { return }
        importingPDF = true
        Task {
            defer { importingPDF = false }
            do {
                let sample = try await LocalExportService().studySample()
                selected = try await store.importPDFAsync(sample.url)
            } catch { store.error = error.localizedDescription }
        }
    }

    private func documentRow(_ document: LibraryDocument) -> some View {
        LibraryDocumentRow(document: document, url: store.url(for: document))
    }

    @ViewBuilder private func documentActions(_ document: LibraryDocument) -> some View {
        Button {
            renameTarget = document
            renameText = document.title
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Menu("Move to collection") {
            Button("Unfiled") { store.move(document.id, folder: nil) }
            ForEach(folders, id: \.self) { folder in
                Button(folder) { store.move(document.id, folder: folder) }
            }
            Divider()
            Button("New collection…") {
                moveTarget = document
                folderText = ""
            }
        }
        Divider()
        Button(role: .destructive) {
            deleteTarget = document
        } label: {
            Label("Delete from library", systemImage: "trash")
        }
    }
}
