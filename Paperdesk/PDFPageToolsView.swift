import SwiftUI
import UniformTypeIdentifiers

struct PDFPageToolsView: View {
    let url: URL
    let expectedVersion: PDFFileVersion
    let onCommit: (PDFPageToolsResult) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var session: PDFPageToolsSession?
    @State private var rows: [PDFPageToolsRow] = []
    @State private var history: [[PDFPageOperation]] = []
    @State private var selected: Set<Int> = []
    @State private var task: Task<Void, Never>?
    @State private var busy: String?
    @State private var saving = false
    @State private var error: String?
    @State private var merging = false
    @State private var confirmDiscard = false
    @State private var confirmDelete = false
    @State private var export: PDFPageExport?
    @State private var movingExport = false

    private var operations: [PDFPageOperation] { history.flatMap { $0 } }
    private var canEdit: Bool { busy == nil && session != nil && session?.restriction == nil }
    private var singleIndex: Int? { selected.count == 1 ? selected.first : nil }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperdeskBackdrop()
                VStack(spacing: 0) {
                    header
                    if let session {
                        if let restriction = session.restriction {
                            Label(restriction.localizedDescription, systemImage: "lock.shield")
                                .font(.callout).padding().frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background)
                        }
                        List {
                            ForEach(rows.indices, id: \.self) { index in
                                Button {
                                    if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
                                } label: {
                                    PDFPageToolsRowView(row: rows[index], position: index + 1, selected: selected.contains(index))
                                }
                                .buttonStyle(.plain)
                                .disabled(busy != nil)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    } else if busy != nil {
                        Spacer(); ProgressView("Reading page information…"); Spacer()
                    } else {
                        ContentUnavailableView("Pages unavailable", systemImage: "doc.badge.exclamationmark", description: Text("Close this sheet and reopen the document to try again."))
                    }
                    if canEdit || busy != nil { actions }
                }
            }
            .navigationTitle("Organize pages")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if history.isEmpty { task?.cancel(); dismiss() } else { confirmDiscard = true }
                    }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save changes") { save() }.disabled(!canEdit || history.isEmpty)
                }
            }
        }
        .tint(PaperdeskPalette.teal)
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 680, minHeight: 600)
        #endif
        .interactiveDismissDisabled(saving || !history.isEmpty)
        .onAppear { load() }
        .onDisappear { if !saving { task?.cancel() } }
        .fileImporter(isPresented: $merging, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): merge(urls)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .fileMover(isPresented: $movingExport, file: export?.url) { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
            export = nil
        }
        .confirmationDialog("Discard pending page changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { task?.cancel(); dismiss() }
        }
        .confirmationDialog("Delete \(selected.count) selected pages?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete pages", role: .destructive) { plan([.delete(indices: selected.sorted())], selectionAfter: []) }
        } message: { Text("The PDF is changed only when you choose Save changes.") }
        .alert("Page tools", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(rows.count) pages", systemImage: "square.stack").font(.headline)
                Spacer()
                if !selected.isEmpty { Text("\(selected.count) selected").font(.callout).foregroundStyle(.secondary) }
                Button(selected.count == rows.count && !rows.isEmpty ? "Deselect all" : "Select all") {
                    selected = selected.count == rows.count ? [] : Set(rows.indices)
                }.disabled(busy != nil || rows.isEmpty)
            }
            Text("Reorder, rotate and combine your PDF locally. Changes to signed PDFs can invalidate signatures; signed and encrypted documents are protected here.")
                .font(.caption).foregroundStyle(.secondary)
            if let busy { HStack { ProgressView().controlSize(.small); Text(busy).font(.caption) } }
        }.padding().background(.background)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { editButtons }
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 10) { editButtons } }
            }
            HStack {
                Button("Merge PDFs", systemImage: "doc.on.doc") { merging = true }.disabled(!canEdit)
                Button("Export selected", systemImage: "square.and.arrow.up") { split() }.disabled(!canEdit || selected.isEmpty)
                Spacer()
                Button("Undo") { undo() }.disabled(!canEdit || history.isEmpty)
            }
            Text("Edits are staged until Save. Splitting exports a separate PDF and leaves the library original untouched. Check forms and document bookmarks after merging or duplicating pages.")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12).paperdeskActions().background(.background)
    }

    @ViewBuilder private var editButtons: some View {
        Button { if let index = singleIndex { plan([.move(from: index, to: index - 1)], selectionAfter: [index - 1]) } } label: { Label("Up", systemImage: "arrow.up") }.disabled(!canEdit || (singleIndex ?? 0) <= 0)
        Button { if let index = singleIndex { plan([.move(from: index, to: index + 1)], selectionAfter: [index + 1]) } } label: { Label("Down", systemImage: "arrow.down") }.disabled(!canEdit || singleIndex == nil || (singleIndex ?? rows.count) >= rows.count - 1)
        Button { plan([.rotate(indices: selected.sorted(), clockwiseDegrees: 90)], selectionAfter: selected) } label: { Label("Rotate", systemImage: "rotate.right") }.disabled(!canEdit || selected.isEmpty)
        Button { plan(selected.sorted(by: >).map { .duplicate(index: $0) }, selectionAfter: []) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.disabled(!canEdit || selected.isEmpty)
        Button { plan([.insertBlank(at: (singleIndex.map { $0 + 1 }) ?? rows.count)], selectionAfter: []) } label: { Label("Blank", systemImage: "doc.badge.plus") }.disabled(!canEdit)
        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }.disabled(!canEdit || selected.isEmpty || selected.count >= rows.count)
    }

    private func run(_ label: String, saving: Bool = false, work: @escaping @MainActor () async throws -> Void) {
        guard busy == nil else { return }
        busy = label; self.saving = saving
        task = Task {
            do { try await work() }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
            self.saving = false; busy = nil
        }
    }

    private func load() {
        guard session == nil else { return }
        run("Reading page information…") {
            let loaded = try await PDFWriteService.shared.openPageTools(url: url, expectedVersion: expectedVersion)
            try Task.checkCancellation()
            session = loaded; rows = loaded.rows
        }
    }

    private func plan(_ additions: [PDFPageOperation], selectionAfter: Set<Int>) {
        guard let session, !additions.isEmpty else { return }
        let candidate = history + [additions]
        run("Updating page layout…") {
            let updated = try await PDFWriteService.shared.pageToolsRows(session: session, operations: candidate.flatMap { $0 })
            try Task.checkCancellation()
            history = candidate; rows = updated; selected = selectionAfter
        }
    }

    private func undo() {
        guard let session, !history.isEmpty else { return }
        let candidate = Array(history.dropLast())
        run("Undoing page layout…") {
            let updated = try await PDFWriteService.shared.pageToolsRows(session: session, operations: candidate.flatMap { $0 })
            try Task.checkCancellation()
            history = candidate; rows = updated; selected = []
        }
    }

    private func merge(_ urls: [URL]) {
        guard let session, !urls.isEmpty else { return }
        run("Copying PDFs for merge…") {
            let imported = try await PDFWriteService.shared.stagePageMerge(urls: urls)
            let candidate = history + [imported.map { .merge($0) }]
            let updated = try await PDFWriteService.shared.pageToolsRows(session: session, operations: candidate.flatMap { $0 })
            try Task.checkCancellation()
            history = candidate; rows = updated; selected = []
        }
    }

    private func split() {
        let operations = operations, indices = selected.sorted()
        run("Preparing selected pages…") {
            let prepared = try await PDFWriteService.shared.exportPageSelection(url: url, expectedVersion: expectedVersion, operations: operations, indices: indices)
            try Task.checkCancellation()
            export = prepared; movingExport = true
        }
    }

    private func save() {
        let operations = operations
        run("Writing PDF pages locally…", saving: true) {
            let result = try await PDFWriteService.shared.applyPageOperations(url: url, expectedVersion: expectedVersion, operations: operations)
            await onCommit(result)
            dismiss()
        }
    }
}

private struct PDFPageToolsRowView: View {
    let row: PDFPageToolsRow
    let position: Int
    let selected: Bool
    @State private var thumbnail: Data?
    private struct ThumbnailIdentity: Hashable { let url: URL?; let page: Int?; let rotation: Int }
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.background)
                if let thumbnail {
                    #if os(macOS)
                    if let image = NSImage(data: thumbnail) { Image(nsImage: image).resizable().scaledToFit() }
                    #else
                    if let image = UIImage(data: thumbnail) { Image(uiImage: image).resizable().scaledToFit() }
                    #endif
                } else { Image(systemName: "doc").font(.title2).foregroundStyle(.secondary) }
            }.frame(width: 48, height: 62).clipShape(RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.2)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Page \(position)").font(.headline)
                Text(row.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if row.rotationDelta % 360 != 0 { Text("Rotated \((row.rotationDelta % 360 + 360) % 360)°").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? PaperdeskPalette.teal : .secondary)
        }.padding(.vertical, 5).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: ThumbnailIdentity(url: row.sourceURL, page: row.sourceIndex, rotation: row.rotationDelta)) {
            thumbnail = nil
            do {
                let image = try await PDFPageToolsThumbnailCache.shared.thumbnail(row: row)
                try Task.checkCancellation(); thumbnail = image
            } catch {}
        }
    }
}
