import PDFKit
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import PencilKit
#endif

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf, .plainText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// Ownership moves once from the loading task to the main actor; never shared concurrently.
private struct LoadedPDF: @unchecked Sendable {
    let document: PDFDocument
    let snapshot: PDFFileSnapshot
}

@MainActor @Observable final class ReaderModel {
    private(set) var document: PDFDocument?
    private(set) var loading = true
    private var restoredPage: Int
    private(set) var fileVersion: PDFFileVersion?
    @ObservationIgnored private var journalState: PDFJournalState?
    @ObservationIgnored private var appliedJournalPages: Set<Int> = []
    @ObservationIgnored var historyDocument: LibraryDocument?
    var largeDocument: Bool { (document?.pageCount ?? 0) >= 1_000 }
    @ObservationIgnored private var fileSnapshot: PDFFileSnapshot?
    var thumbnailURL: URL? { fileSnapshot?.url }
    let view = PDFView()
    @ObservationIgnored lazy var ink = InlinePDFInk(reader: self)
    let url: URL
    let textService = DocumentTextService()
    var page = 0
    var query = ""
    var matches: [DocumentSearchHit] = []
    var matchIndex = 0
    var searched = false
    var searching = false
    var saving = false
    var editingLocked = false
    var error: String?
    var recognizing = false
    var recognizedText = ""
    var ocrProgress = 0.0
    var searchProgress = 0.0
    var status: String?
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var ocrTask: Task<Void, Never>?
    @ObservationIgnored var searchGeneration = UUID()
    init(url: URL, page: Int) {
        self.url = url
        restoredPage = page
        self.page = max(0, page)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageOverlayViewProvider = ink
    }

    func load() async {
        guard document == nil else { return }
        loading = true
        defer { loading = false }
        let url = url
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let snapshot = try PDFFileSnapshot(copying: url)
            guard let pdf = PDFDocument(url: snapshot.url), !pdf.isLocked, pdf.pageCount > 0 else {
                throw DocumentTextError.unreadablePDF
            }
            return LoadedPDF(document: pdf, snapshot: snapshot)
        }
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            document = loaded.document
            fileSnapshot = loaded.snapshot
            fileVersion = loaded.snapshot.version
            journalState = try await PDFPageJournal.shared.state(
                for: url, sourceVersion: loaded.snapshot.version)
            view.displayMode = largeDocument ? .singlePage : .singlePageContinuous
            view.document = document
            let initial = max(0, min(restoredPage, loaded.document.pageCount - 1))
            if let initialPage = document?.page(at: initial) { await loadJournalPage(initialPage) }
            go(initial)
        } catch is CancellationError {} catch {
            self.error = "Could not open PDF: \(error.localizedDescription)"
        }
    }
    func go(_ index: Int) {
        guard let target = document?.page(at: index) else { return }
        view.go(to: target)
        page = index
    }
    func journalPageReady(_ page: PDFPage) -> Bool {
        guard let document else { return false }
        let index = document.index(for: page)
        return journalState?.pages[index] == nil || appliedJournalPages.contains(index)
    }
    func loadJournalPage(_ page: PDFPage) async {
        guard let document, let state = journalState else { return }
        let index = document.index(for: page)
        guard state.pages[index] != nil, !appliedJournalPages.contains(index) else { return }
        do {
            if let data = try await PDFPageJournal.shared.pageData(url: url, index: index, state: state) {
                guard self.document === document else { return }
                try PDFPageJournal.apply(data: data, to: page)
            }
            appliedJournalPages.insert(index)
        } catch { self.error = "Could not load saved ink: \(error.localizedDescription)" }
    }
    func materializedExport() async throws -> TemporaryExport {
        guard let fileVersion else { throw CocoaError(.fileReadUnknown) }
        let file = try TemporaryExport(filename: "Document.pdf")
        defer { withExtendedLifetime(file) {} }
        try await PDFPageJournal.shared.materialize(url: url, to: file.url, expectedVersion: fileVersion)
        return file
    }
    func reload() async {
        restoredPage = page
        ink.active = false
        view.document = nil
        document = nil
        journalState = nil
        appliedJournalPages.removeAll()
        ink.resetForReload()
        await load()
    }
    /// Structural edits explicitly consolidate the journal once, away from the UI executor.
    func consolidateJournal() async throws {
        let wasLocked = editingLocked
        editingLocked = true
        defer { editingLocked = wasLocked }
        ink.active = false
        try await ink.flushAndWait()
        guard let fileVersion, let journalState else { return }
        let previousFingerprint = try DocumentTextService.cacheFingerprint(url: url, pageCount: document?.pageCount ?? 0)
        let file = try await materializedExport()
        defer { withExtendedLifetime(file) {} }
        try await PDFPageJournal.shared.commitMaterialized(
            url: url, temporary: file.url, expectedVersion: fileVersion, expectedRevision: journalState.revision)
        try? await textService.refreshIndexFingerprint(url: url, previousFingerprint: previousFingerprint)
        await reload()
    }
    func resetSearch() {
        searchTask?.cancel()
        searchGeneration = UUID()
        matches = []
        matchIndex = 0
        searched = false
        searching = false
        view.highlightedSelections = []
        view.clearSelection()
    }
    func search() {
        resetSearch()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searching = true
        let generation = searchGeneration
        let query = query
        searchTask = Task {
            do {
                var results = try await textService.search(url: url, query: query) { progress in
                    await MainActor.run {
                        if self.searchGeneration == generation { self.searchProgress = progress.fraction }
                    }
                }
                results.append(contentsOf: try await HandwritingService.shared.search(url: url, query: query))
                guard !Task.isCancelled, generation == searchGeneration else { return }
                matches = results
                searched = true
                searching = false
                revealMatch()
            } catch is CancellationError { if generation == searchGeneration { searching = false } } catch {
                if generation == searchGeneration {
                    searching = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
    func revealMatch() {
        guard matches.indices.contains(matchIndex) else {
            view.clearSelection()
            return
        }
        let hit = matches[matchIndex]
        go(hit.pageIndex)
        if !hit.isOCR, let selection = document?.page(at: hit.pageIndex)?.selection(for: hit.range) {
            view.setCurrentSelection(selection, animate: false)
            view.go(to: selection)
        } else {
            view.clearSelection()
        }
    }
    func savePDF(pageIndices: [Int]? = nil) async throws {
        guard !saving, let document, let fileVersion else { throw CocoaError(.fileWriteUnknown) }
        saving = true
        defer { saving = false }
        var snapshots: [Int: Data] = [:]
        for index in Set(pageIndices ?? [page]) {
            guard let page = document.page(at: index), journalPageReady(page) else {
                throw CocoaError(.fileWriteUnknown)
            }
            snapshots[index] = try PDFAnnotationSnapshot.data(from: page)
        }
        if let document = historyDocument {
            _ = try? await DocumentHistoryService.shared.capture(
                document: document, library: url.deletingLastPathComponent(), reason: "Before annotations")
        }
        if largeDocument || journalState != nil {
            journalState = try await PDFPageJournal.shared.save(
                url: url, pages: snapshots, sourceVersion: fileVersion,
                expectedRevision: journalState?.revision)
            appliedJournalPages.formUnion(snapshots.keys)
        } else {
            let previousFingerprint = try DocumentTextService.cacheFingerprint(url: url, pageCount: document.pageCount)
            self.fileVersion = try await PDFWriteService.shared.savePages(
                url: url, pages: snapshots, expectedVersion: fileVersion)
            try? await textService.refreshIndexFingerprint(url: url, previousFingerprint: previousFingerprint)
        }
        status = "Saved"
    }
    func highlight() {
        guard !saving, !editingLocked, let selection = view.currentSelection, !(selection.string ?? "").isEmpty, let document
        else {
            error = "Select PDF text first, then choose Highlight."
            return
        }
        var added: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let annotation = PDFAnnotation(
                    bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                annotation.color = .systemYellow.withAlphaComponent(0.45)
                page.addAnnotation(annotation)
                added.append((page, annotation))
            }
        }
        let indices = added.map { document.index(for: $0.0) }
        Task {
            do {
                try await savePDF(pageIndices: indices)
                view.clearSelection()
            } catch {
                for (page, annotation) in added { page.removeAnnotation(annotation) }
                self.error = error.localizedDescription
            }
        }
    }
    func recognize(allPages: Bool = false) {
        guard !recognizing else { return }
        recognizing = true
        ocrProgress = 0
        recognizedText = ""
        let pages: [Int]? = allPages ? nil : [page]
        ocrTask = Task {
            do {
                let index = try await textService.recognize(url: url, pages: pages) { progress in
                    await MainActor.run { self.ocrProgress = progress.fraction }
                }
                try Task.checkCancellation()
                let selected = index.pages.filter { pages == nil || pages!.contains($0.pageIndex) }.sorted {
                    $0.pageIndex < $1.pageIndex
                }
                recognizedText = selected.prefix(250).map { "Page \($0.pageIndex + 1)\n\($0.text)" }.joined(
                    separator: "\n\n")
                recognizedText = String(recognizedText.prefix(200_000))
                status = "OCR saved; PDF search includes recognized pages"
            } catch is CancellationError { status = "OCR stopped; completed pages are saved" } catch {
                self.error = "OCR failed: \(error.localizedDescription)"
            }
            recognizing = false
        }
    }
    func recognizeHandwriting(allPages: Bool = false) {
        guard !recognizing else { return }
        recognizing = true
        recognizedText = ""
        ocrProgress = 0
        let page = page
        ocrTask = Task {
            defer { recognizing = false }
            do {
                ink.active = false
                try await ink.flushAndWait()
                if allPages {
                    let count = try await HandwritingService.shared.indexDocument(url: url) { value in
                        await MainActor.run { self.ocrProgress = value }
                    }
                    status = "Indexed handwriting on \(count) pages"
                } else {
                    recognizedText = try await HandwritingService.shared.recognize(url: url, pageIndex: page).text
                    ocrProgress = 1
                }
            } catch is CancellationError { status = "Handwriting indexing stopped" }
            catch { self.error = error.localizedDescription }
        }
    }
    func stop() {
        searchTask?.cancel()
        ocrTask?.cancel()
    }
}

struct ReaderView: View {
    let store: LibraryStore
    let item: LibraryDocument
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: ReaderModel
    @State private var workspace: WorkspaceStore
    @State private var workspaceSheet = false
    @State private var historySheet = false
    @State private var pageTools = false
    @State private var preparingTools = false
    @State private var showThumbnails = false
    @State private var comparison: LibraryDocument?
    @State private var showNotes = true
    @State private var notesSheet = false
    @State private var handwritingSheet = false
    @State private var pageInput = ""
    @State private var showJump = false
    @State private var exporting = false
    @State private var exportingPDF = false
    @State private var pdfExport: PDFExportItem?
    @State private var exportFile = ExportFile(data: Data())
    @State private var exportType = UTType.pdf
    @State private var exportName = "Document"
    @State private var ocrSheet = false
    @State private var editPage = false
    @State private var studySheet = false
    @State private var preparingExport = false
    @State private var confirmSearchableExport = false
    @State private var exportTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    init(store: LibraryStore, item: LibraryDocument) {
        self.store = store
        self.item = item
        _workspace = State(initialValue: WorkspaceStore(documentID: item.id, directory: store.directory))
        _model = State(initialValue: ReaderModel(url: store.url(for: item), page: item.lastPage))
    }
    private var compact: Bool { sizeClass == .compact }
    private var notes: Binding<String> {
        Binding(
            get: { store.documents.first(where: { $0.id == item.id })?.notes ?? "" },
            set: { store.update(item.id, notes: $0, deferred: true) })
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search PDF", text: $model.query).textFieldStyle(.roundedBorder).onSubmit {
                        model.search()
                    }.onChange(of: model.query) { _, _ in
                        model.resetSearch()
                    }
                    Button(model.searching ? "Stop" : "Find") {
                        if model.searching { model.resetSearch() } else { model.search() }
                    }.disabled(model.document == nil || model.saving)
                }
                if model.searching || model.searched {
                    HStack(spacing: 8) {
                        if model.searching { ProgressView(value: model.searchProgress).frame(width: 45) }
                        if model.searched {
                            Text(
                            model.matches.isEmpty ? "0 results" : "\(model.matchIndex + 1)/\(model.matches.count)"
                            ).font(.caption).monospacedDigit()
                            Button {
                                model.matchIndex = (model.matchIndex + 1) % max(1, model.matches.count)
                                model.revealMatch()
                            } label: {
                                Image(systemName: "chevron.down")
                            }.disabled(model.matches.isEmpty).accessibilityLabel("Next search result")
                        }
                    }
                }
            }.padding(8).background(.background).paperdeskActions()
            if model.matches.indices.contains(model.matchIndex) {
                Text(model.matches[model.matchIndex].snippet).font(.caption).lineLimit(2).frame(
                    maxWidth: .infinity, alignment: .leading
                ).padding(.horizontal, 12)
            }
            Divider()
            if let comparison, compact {
                DisclosureGroup("Second reader · " + comparison.title) {
                    CompanionReader(url: store.url(for: comparison), title: comparison.title, initialPage: comparison.lastPage)
                        .id(comparison.id).frame(height: 280)
                }.padding(.horizontal)
            }
            if model.ink.active { InlineInkBar(ink: model.ink) }
            HStack(spacing: 0) {
                if showThumbnails, let url = model.thumbnailURL {
                    ReaderThumbnailRail(url: url, pageCount: model.document?.pageCount ?? 0, currentPage: model.page, onPage: model.go)
                        .frame(width: compact ? 72 : 110)
                }
                if model.loading {
                    ProgressView("Opening PDF…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.document != nil {
                    PDFCanvas(model: model)
                } else {
                    ContentUnavailableView(
                        "PDF unavailable", systemImage: "doc.badge.exclamationmark",
                        description: Text("The library copy could not be opened. Import the PDF again."))
                }
                if let comparison, !compact {
                    Divider()
                    CompanionReader(url: store.url(for: comparison), title: comparison.title, initialPage: comparison.lastPage)
                        .id(comparison.id)
                }
                if showNotes && !compact && !model.ink.active && comparison == nil {
                    Divider()
                    notesPanel.frame(minWidth: 220, idealWidth: 270, maxWidth: 320)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ReaderDock(
                model: model,
                onJump: {
                    pageInput = "\(model.page + 1)"
                    showJump = true
                })
        }
        .background { PaperdeskBackdrop() }
        .task {
            model.historyDocument = store.documents.first { $0.id == item.id }
            await model.load()
        }
        .onDisappear { Task { await DocumentCoverCache.shared.invalidate() } }
        .navigationTitle(item.title)
        .toolbar {
            Button {
                studySheet = true
            } label: {
                Label("Offline Study", systemImage: "book.closed")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(model.document == nil || model.saving)
            Button {
                model.ink.active.toggle()
            } label: {
                Label(
                    model.ink.active ? "Finish writing" : "Write on PDF",
                    systemImage: "pencil.tip.crop.circle")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.document == nil || model.saving || model.recognizing || model.editingLocked)
            Button {
                if compact { notesSheet = true } else { showNotes.toggle() }
            } label: {
                Label("Notes", systemImage: "square.and.pencil")
            }
            Menu {
                Button("Study workspace", systemImage: "bookmark.square") { workspaceSheet = true }
                Button("Version history", systemImage: "clock.arrow.circlepath") { historySheet = true }
                Button("Organize pages", systemImage: "square.stack") { preparePageTools() }
                    .disabled(model.saving || preparingTools || model.document == nil)
                Toggle("Page thumbnails", isOn: $showThumbnails)
                Menu("Read alongside") {
                    Button("This document") { comparison = item }
                    ForEach(store.documents) { document in
                        Button(document.title) { comparison = document }
                    }
                    if comparison != nil { Button("Close second reader") { comparison = nil } }
                }
                Button("Recognize handwriting on page") { model.recognizeHandwriting(); ocrSheet = true }
                    .disabled(model.recognizing)
                Button("Index handwriting in document") { model.recognizeHandwriting(allPages: true); ocrSheet = true }
                    .disabled(model.recognizing)
                Button("Highlight selected text", systemImage: "highlighter") { model.highlight() }.disabled(
                    model.saving || model.recognizing || model.editingLocked || preparingExport)
                Button("Edit annotations on page", systemImage: "slider.horizontal.3") { editPage = true }
                    .disabled(model.saving || model.recognizing || model.editingLocked)
                Button("Recognize text on page", systemImage: "text.viewfinder") {
                    model.recognize()
                    ocrSheet = true
                }.disabled(model.document == nil || model.recognizing || model.saving)
                Button("Recognize whole document", systemImage: "doc.text.viewfinder") {
                    model.recognize(allPages: true)
                    ocrSheet = true
                }.disabled(model.document == nil || model.recognizing || model.saving)
                Button("Export searchable PDF", systemImage: "doc.text.magnifyingglass") {
                    confirmSearchableExport = true
                }.disabled(model.document == nil || model.recognizing || model.saving || preparingExport)
                Divider()
                Button("Export PDF", systemImage: "square.and.arrow.up") {
                    preparePDFExport(searchable: false)
                }.disabled(model.document == nil || model.saving || preparingExport)
                Button("Export notes", systemImage: "doc.text") {
                    exportFile = ExportFile(data: Data(notes.wrappedValue.utf8))
                    exportType = .plainText
                    exportName = item.title + " Notes"
                    exporting = true
                }
            } label: {
                Label("Tools", systemImage: "ellipsis.circle")
            }
        }
        .sheet(isPresented: $workspaceSheet) {
            NavigationStack {
                WorkspacePanel(store: workspace, currentPage: model.page, selection: workspaceSelection, onNavigate: navigate)
                    .navigationTitle("Study workspace")
                    .toolbar { Button("Done") { workspaceSheet = false } }
            }.frame(minWidth: 300, minHeight: 450)
        }
        .sheet(isPresented: $historySheet) { DocumentHistoryView(store: store, documentID: item.id) }
        .sheet(isPresented: $pageTools) {
            if let version = model.fileVersion {
                PDFPageToolsView(url: model.url, expectedVersion: version) { result in
                    do { try await workspace.remapPages(originalToNew: result.originalToNew) }
                    catch { model.error = "PDF saved, but workspace remapping failed: \(error.localizedDescription)" }
                    model.page = result.originalToNew[model.page] ?? min(model.page, result.pageCount - 1)
                    store.update(item.id, page: model.page)
                    await model.reload()
                }
            }
        }
        .sheet(isPresented: $studySheet) {
            OfflineStudyView(
                url: model.url, title: item.title, currentPage: model.page,
                onPage: { model.go($0) },
                onSaveNote: { try store.appendStudyNote(item.id, text: $0) },
                onSaveCards: { cards in
                    if !workspace.isLoaded { await workspace.load() }
                    _ = try await workspace.addCards(cards.map {
                        WorkspaceCardInput(question: $0.prompt, answer: $0.answer.text, pageIndex: $0.answer.pageIndex, bounds: nil)
                    })
                })
        }
        .sheet(isPresented: $editPage) {
            if let page = model.document?.page(at: model.page) {
                PDFPageEditor(
                    page: page, onChange: { try await model.savePDF() }, onError: { model.error = $0 }
                )
                .interactiveDismissDisabled()
            }
        }
        .confirmationDialog(
            "Create searchable copy?", isPresented: $confirmSearchableExport, titleVisibility: .visible
        ) {
            Button("Create searchable PDF") { preparePDFExport(searchable: true) }
        } message: {
            Text(
                "The copy keeps the page appearance and searchable text. Annotations become permanent page content; links, forms and bookmarks are omitted. Your library original stays editable."
            )
        }
        .fileExporter(
            isPresented: $exportingPDF, item: pdfExport, contentTypes: [.pdf], defaultFilename: exportName
        ) { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
            if case .success = result { model.status = "PDF exported" }
            pdfExport = nil
        } onCancellation: {
            pdfExport = nil
        }
        .fileExporter(
            isPresented: $exporting, document: exportFile, contentType: exportType,
            defaultFilename: exportName
        ) { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
        }
        .sheet(isPresented: $notesSheet) {
            NavigationStack {
                notesPanel.navigationTitle("Notes").toolbar { Button("Done") { notesSheet = false } }
            }.frame(minWidth: 300, minHeight: 400)
        }
        .sheet(isPresented: $ocrSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recognized page text").font(.headline)
                if model.recognizing {
                    ProgressView("Recognizing text…", value: model.ocrProgress)
                    Button("Stop OCR") { model.ocrTask?.cancel() }
                } else {
                    ScrollView {
                        Text(model.recognizedText).textSelection(.enabled).frame(
                            maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Copy text") {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.recognizedText, forType: .string)
                        #else
                        UIPasteboard.general.string = model.recognizedText
                        #endif
                    }.disabled(model.recognizedText.isEmpty)
                    Button("Append to notes") {
                        notes.wrappedValue += "\n\n" + model.recognizedText
                        ocrSheet = false
                    }.disabled(model.recognizedText.isEmpty)
                }
                Button("Done") { ocrSheet = false }
            }.padding().frame(minWidth: 300, minHeight: 350)
        }
        .alert("Go to page", isPresented: $showJump) {
            TextField("Page number", text: $pageInput)
            Button("Go") {
                if let page = Int(pageInput), page > 0, page <= (model.document?.pageCount ?? 0) {
                    model.go(page - 1)
                } else {
                    model.error = "Enter a page from 1 to \(model.document?.pageCount ?? 0)."
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Reader", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
        ) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: model.view)) { _ in
            if let page = model.view.currentPage, let document = model.document {
                model.page = document.index(for: page)
                store.update(item.id, page: model.page, deferred: true)
            }
        }
        .onChange(of: model.page) { _, page in store.update(item.id, page: page, deferred: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.ink.flush(); store.flushPendingChanges() }
        }
        .onDisappear {
            model.ink.flush()
            model.stop()
            exportTask?.cancel()
            store.flushPendingChanges()
        }
        .safeAreaInset(edge: .bottom) {
            if model.saving || preparingExport || model.recognizing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(
                        model.saving
                            ? "Saving annotations…" : preparingExport ? "Preparing PDF…" : "OCR running…"
                    ).font(.caption)
                    Spacer()
                    if preparingExport { Button("Stop") { exportTask?.cancel() } }
                    if model.recognizing { Button("Progress") { ocrSheet = true } }
                }.padding(8)
            } else if let status = model.status {
                HStack {
                    Label(status, systemImage: "checkmark.circle")
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
    }
    private func workspaceSelection() -> WorkspaceSelection? {
        guard let selection = model.view.currentSelection, let page = selection.pages.first,
            let document = model.document else { return nil }
        return WorkspaceSelection(pageIndex: document.index(for: page), bounds: selection.bounds(for: page), quote: selection.string ?? "")
    }
    private func navigate(_ index: Int, _ region: PDFNoteRegion?) {
        model.go(index)
        if let region, let page = model.document?.page(at: index) { model.view.go(to: region.bounds, on: page) }
        if compact { workspaceSheet = false }
    }
    private func preparePageTools() {
        guard !preparingTools, !model.editingLocked else { return }
        preparingTools = true
        model.editingLocked = true
        Task {
            defer { preparingTools = false; model.editingLocked = false }
            do {
                try await model.consolidateJournal()
                await workspace.load()
                guard workspace.isLoaded else { throw CocoaError(.fileReadCorruptFile) }
                guard let current = store.documents.first(where: { $0.id == item.id }) else { throw CocoaError(.fileNoSuchFile) }
                _ = try await DocumentHistoryService.shared.capture(document: current, library: store.directory, reason: "Before organizing pages", force: true)
                pageTools = true
            } catch { model.error = error.localizedDescription }
        }
    }

    private func preparePDFExport(searchable: Bool) {
        guard !preparingExport, !model.editingLocked else { return }
        preparingExport = true
        model.editingLocked = true
        exportTask = Task {
            defer { preparingExport = false; model.editingLocked = false }
            do {
                model.ink.active = false
                try await model.ink.flushAndWait()
                let file: TemporaryExport
                if searchable {
                    file = try TemporaryExport(filename: "Searchable.pdf")
                    let visual = try await model.materializedExport()
                    defer { withExtendedLifetime(visual) {} }
                    try await model.textService.writeSearchablePDF(url: model.url, to: file.url, visualURL: visual.url) { progress in
                        await MainActor.run { model.ocrProgress = progress.fraction }
                    }
                } else {
                    file = try await model.materializedExport()
                }
                try Task.checkCancellation()
                pdfExport = PDFExportItem(file: file)
                exportName = item.title + (searchable ? " Searchable" : "")
                exportingPDF = true
            } catch is CancellationError {} catch { model.error = error.localizedDescription }
            preparingExport = false
        }
    }
    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Document notes", systemImage: "square.and.pencil").font(.headline)
                Label(
                    store.saveStatus == "Saved" ? "Saved on this device" : store.saveStatus,
                    systemImage: "checkmark.shield"
                )
                .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            TextEditor(text: notes).accessibilityLabel("Document notes").font(.body).padding(6).background(
                .background
            ).clipShape(RoundedRectangle(cornerRadius: 8))
            #if os(iOS)
                Button("Handwritten notes", systemImage: "applepencil.tip") { handwritingSheet = true }
                    .sheet(isPresented: $handwritingSheet) {
                        NavigationStack {
                            HandwritingView(
                                url: store.directory.appendingPathComponent(item.id.uuidString + ".drawing")
                            )
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { handwritingSheet = false }
                                }
                            }
                        }.interactiveDismissDisabled()
                    }
            #endif
        }.padding().background(.background)
    }
}

#if os(macOS)
    struct PDFCanvas: NSViewRepresentable {
        let model: ReaderModel
        func makeNSView(context: Context) -> PDFView { model.view }
        func updateNSView(_ nsView: PDFView, context: Context) {}
    }
#else
    struct PDFCanvas: UIViewRepresentable {
        let model: ReaderModel
        func makeUIView(context: Context) -> PDFView { model.view }
        func updateUIView(_ uiView: PDFView, context: Context) {}
    }

    struct HandwritingView: View {
        let url: URL
        @State private var canvas = PencilCanvasView()
        @State private var error: String?
        @State private var confirmClear = false
        @AppStorage("Paperdesk.allowFingerDrawing") private var allowFingerDrawing = false
        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "applepencil.tip")
                    Text(
                        allowFingerDrawing
                            ? "Pencil or finger to write · two fingers to scroll"
                            : "Apple Pencil to write · fingers to scroll"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(12).paperdeskChrome().padding(8)
                DrawingCanvas(canvas: canvas, url: url, allowFingerDrawing: allowFingerDrawing, error: $error)
            }
            .background { PaperdeskBackdrop() }
            .paperdeskActions()
            .navigationTitle("Handwritten notes")
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification))
            { _ in
                (canvas.delegate as? DrawingCanvas.Coordinator)?.save(canvas, deferred: false)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        canvas.undoManager?.undo()
                    } label: {
                        Label("Undo stroke", systemImage: "arrow.uturn.backward")
                    }
                    Button {
                        canvas.undoManager?.redo()
                    } label: {
                        Label("Redo stroke", systemImage: "arrow.uturn.forward")
                    }
                    Menu {
                        Toggle("Draw with finger", isOn: $allowFingerDrawing)
                        Button("Show drawing tools") { canvas.showTools() }
                        Button("Clear drawing", role: .destructive) { confirmClear = true }
                    } label: {
                        Label("Drawing options", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Clear all handwritten notes for this document?", isPresented: $confirmClear)
            {
                Button("Clear drawing", role: .destructive) { canvas.drawing = PKDrawing() }
            }
            .alert(
                "Drawing could not be saved",
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    // The canvas owns its palette so it follows the actual UIKit window lifecycle.
    final class PencilCanvasView: PKCanvasView, UIPencilInteractionDelegate {
        let picker = PKToolPicker()
        private var pencilInteraction: UIPencilInteraction?
        private var previousTool: (any PKTool)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            let interaction = UIPencilInteraction()
            interaction.delegate = self
            addInteraction(interaction)
            pencilInteraction = interaction
        }
        required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                picker.addObserver(self)
                showTools()
            } else {
                picker.setVisible(false, forFirstResponder: self)
                picker.removeObserver(self)
            }
        }
        func showTools() {
            guard window != nil else { return }
            becomeFirstResponder()
            picker.setVisible(true, forFirstResponder: self)
        }
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            performPencilAction(UIPencilInteraction.preferredTapAction)
        }
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap)
        {
            performPencilAction(UIPencilInteraction.preferredTapAction)
        }
        @available(iOS 17.5, *)
        func pencilInteraction(
            _ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
        ) {
            guard squeeze.phase == .ended else { return }
            let action = UIPencilInteraction.preferredSqueezeAction
            if action == .showContextualPalette { showTools() } else { performPencilAction(action) }
        }
        private func performPencilAction(_ action: UIPencilPreferredAction) {
            switch action {
            case .switchEraser:
                if tool is PKEraserTool {
                    tool = previousTool ?? PKInkingTool(.pen, color: .label, width: 3)
                } else {
                    previousTool = tool
                    tool = PKEraserTool(.vector)
                }
            case .switchPrevious:
                let current = tool
                tool = previousTool ?? PKEraserTool(.vector)
                previousTool = current
            case .showColorPalette, .showInkAttributes:
                showTools()
            default: break
            }
        }
    }

    /// Acquired before scheduling work, and balanced on success, failure, cancellation or expiry.
    @MainActor final class DrawingSaveLifetime {
        private var identifier: UIBackgroundTaskIdentifier = .invalid
        private let end: (UIBackgroundTaskIdentifier) -> Void
        convenience init() {
            self.init(
                begin: { expiration in
                    UIApplication.shared.beginBackgroundTask(
                        withName: "Save handwriting", expirationHandler: expiration)
                }, end: { UIApplication.shared.endBackgroundTask($0) })
        }
        init(
            begin: (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier,
            end: @escaping (UIBackgroundTaskIdentifier) -> Void
        ) {
            self.end = end
            identifier = begin { [weak self] in self?.finish() }
        }
        func finish() {
            guard identifier != .invalid else { return }
            let active = identifier
            identifier = .invalid
            end(active)
        }
    }

    struct DrawingSnapshot: @unchecked Sendable {
        let drawing: PKDrawing
    }
    /// Shared across notebook coordinators so reopened views cannot reuse an older revision.
    @MainActor enum DrawingRevisionSequence {
        private static var revision: UInt64 = 0

        static func next() -> UInt64 {
            revision += 1
            return revision
        }
    }

    actor DrawingSaveService {
        static let shared = DrawingSaveService()
        private var latest: [URL: UInt64] = [:]
        func save(_ snapshot: DrawingSnapshot, url: URL, revision: UInt64) throws {
            guard revision > latest[url, default: 0] else { return }
            try snapshot.drawing.dataRepresentation().write(to: url, options: .atomic)
            latest[url] = revision
        }
    }

    struct DrawingCanvas: UIViewRepresentable {
        let canvas: PencilCanvasView
        let url: URL
        let allowFingerDrawing: Bool
        @Binding var error: String?
        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
        func makeUIView(context: Context) -> PencilCanvasView {
            canvas.drawingPolicy = allowFingerDrawing ? .anyInput : .pencilOnly
            canvas.tool = PKInkingTool(.pen, color: .label, width: 3)
            canvas.backgroundColor = .systemBackground
            canvas.contentSize = CGSize(width: 1600, height: 2200)
            canvas.minimumZoomScale = 0.25
            canvas.maximumZoomScale = 4
            canvas.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 120, right: 0)
            if FileManager.default.fileExists(atPath: url.path) {
                do { canvas.drawing = try PKDrawing(data: Data(contentsOf: url)) } catch {
                    context.coordinator.canSave = false
                    let message = "Saved drawing could not be read: \(error.localizedDescription)"
                    DispatchQueue.main.async { self.error = message }
                }
            }
            canvas.delegate = context.coordinator
            return canvas
        }
        func updateUIView(_ uiView: PencilCanvasView, context: Context) {
            context.coordinator.parent = self
            uiView.drawingPolicy = allowFingerDrawing ? .anyInput : .pencilOnly
        }
        static func dismantleUIView(_ uiView: PencilCanvasView, coordinator: Coordinator) {
            coordinator.save(uiView, deferred: false)
            uiView.picker.setVisible(false, forFirstResponder: uiView)
            uiView.picker.removeObserver(uiView)
            uiView.resignFirstResponder()
            uiView.delegate = nil
        }
        @MainActor class Coordinator: NSObject, PKCanvasViewDelegate {
            var parent: DrawingCanvas
            var canSave = true
            private var pending: Task<Void, Never>?
            init(parent: DrawingCanvas) { self.parent = parent }
            func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { save(canvasView) }
            func save(_ canvasView: PKCanvasView, deferred: Bool = true) {
                guard canSave else { return }
                pending?.cancel()
                let snapshot = DrawingSnapshot(drawing: canvasView.drawing)
                let revision = DrawingRevisionSequence.next()
                let url = parent.url
                let lifetime = DrawingSaveLifetime()
                pending = Task {
                    defer { lifetime.finish() }
                    if deferred { do { try await Task.sleep(for: .milliseconds(300)) } catch { return } }
                    do {
                        try await DrawingSaveService.shared.save(snapshot, url: url, revision: revision)
                    } catch { parent.error = error.localizedDescription }
                }
            }
        }
    }
#endif
