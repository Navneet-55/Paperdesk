import SwiftUI

struct WorkspacePanel: View {
    @Bindable var store: WorkspaceStore
    let currentPage: Int
    let selection: () -> WorkspaceSelection?
    let onNavigate: (Int, PDFNoteRegion?) -> Void
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Study workspace", systemImage: "bookmark.square")
                        .font(.headline)
                    Spacer()
                    if store.isSaving { ProgressView().controlSize(.small) }
                    Button { Task { await store.load() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload workspace").help("Reload changes from other windows").disabled(store.isSaving || store.isLoading)
                }
                Picker("Workspace", selection: $tab) {
                    Text("Bookmarks").tag(0)
                    Text("Margin notes").tag(1)
                    Text("Review").tag(2)
                }.pickerStyle(.menu)
                Text(store.saveStatus).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            if store.isLoaded {
                switch tab {
                case 0: WorkspaceBookmarksView(store: store, currentPage: currentPage, onNavigate: onNavigate)
                case 1: WorkspaceNotesView(store: store, currentPage: currentPage, selection: selection, onNavigate: onNavigate)
                default: WorkspaceReviewView(store: store, currentPage: currentPage, selection: selection, onNavigate: onNavigate)
                }
            } else if store.isLoading {
                ProgressView("Loading workspace…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Workspace unavailable", systemImage: "bookmark.slash")
                } description: { Text("Your saved workspace file stays untouched if it cannot be read.") }
                actions: { Button("Reload workspace") { Task { await store.load() } } }
            }
        }
        .paperdeskActions()
        .task { if !store.isLoaded { await store.load() } }
        .alert("Workspace", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct WorkspaceBookmarksView: View {
    let store: WorkspaceStore
    let currentPage: Int
    let onNavigate: (Int, PDFNoteRegion?) -> Void
    @State private var editing: WorkspaceBookmark?
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Bookmark page \(currentPage + 1)", systemImage: "bookmark") {
                    Task { try? await store.bookmark(pageIndex: currentPage) }
                }.disabled(store.isSaving || currentPage < 0)
                Spacer()
            }.padding(.horizontal, 12)
            List {
                ForEach(store.bookmarks) { bookmark in
                    HStack {
                        Button { onNavigate(bookmark.pageIndex, nil) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bookmark.title).font(.headline)
                                Text("Page \(bookmark.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Menu {
                            Button("Rename") { editing = bookmark }
                            Button("Remove bookmark", role: .destructive) { Task { try? await store.removeBookmark(bookmark.id) } }
                        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Bookmark actions")
                    }.padding(.vertical, 4)
                }
            }
            .overlay { if store.bookmarks.isEmpty { ContentUnavailableView("Keep a place", systemImage: "bookmark", description: Text("Bookmark important pages to return to them quickly.")) } }
        }
        .sheet(item: $editing) { bookmark in
            WorkspaceTextSheet(title: "Rename bookmark", initialText: bookmark.title, fieldLabel: "Title") { text in
                try await store.bookmark(pageIndex: bookmark.pageIndex, title: text)
            }
        }
    }
}

private struct MarginNoteDraft: Identifiable {
    let id = UUID()
    let existingID: UUID?
    let selection: WorkspaceSelection
    let body: String
    var sourceRemoved = false
}

struct WorkspaceNotesView: View {
    let store: WorkspaceStore
    let currentPage: Int
    let selection: () -> WorkspaceSelection?
    let onNavigate: (Int, PDFNoteRegion?) -> Void
    @State private var editing: MarginNoteDraft?
    @State private var removing: WorkspaceMarginNote?
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Add margin note", systemImage: "text.bubble") {
                    let captured = selection() ?? WorkspaceSelection(pageIndex: currentPage, bounds: nil, quote: "")
                    editing = MarginNoteDraft(existingID: nil, selection: captured, body: "")
                }.disabled(store.isSaving || currentPage < 0)
                Spacer()
            }.padding(.horizontal, 12)
            List {
                ForEach(store.marginNotes) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if note.sourceRemoved {
                                Label("Source page removed", systemImage: "doc.badge.minus").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Page \(note.pageIndex + 1)", systemImage: note.region == nil ? "doc" : "viewfinder") { onNavigate(note.pageIndex, note.region) }
                            }
                            Spacer()
                            Menu {
                                Button("Edit note") {
                                    editing = MarginNoteDraft(existingID: note.id, selection: WorkspaceSelection(pageIndex: note.pageIndex, bounds: note.region?.bounds, quote: note.quote), body: note.body, sourceRemoved: note.sourceRemoved)
                                }
                                Button("Delete note", role: .destructive) { removing = note }
                            } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Margin note actions")
                        }
                        if !note.quote.isEmpty { Text(String(note.quote.prefix(1000))).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        Text(note.body).lineLimit(5).textSelection(.enabled)
                    }.padding(.vertical, 6)
                }
            }
            .overlay { if store.marginNotes.isEmpty { ContentUnavailableView("Write beside the source", systemImage: "text.bubble", description: Text("Select text in your PDF, then add a note linked to that region. You can also leave a page note.")) } }
        }
        .sheet(item: $editing) { draft in
            WorkspaceTextSheet(title: draft.existingID == nil ? "Add margin note" : "Edit margin note", initialText: draft.body, fieldLabel: "Your note", context: (draft.sourceRemoved ? "Source page removed" : "Page \(draft.selection.pageIndex + 1)") + (draft.selection.quote.isEmpty ? "" : " · \(String(draft.selection.quote.prefix(1000)))")) { body in
                if let id = draft.existingID { try await store.editMarginNote(id, body: body) }
                else { try await store.addMarginNote(pageIndex: draft.selection.pageIndex, bounds: draft.selection.bounds, quote: draft.selection.quote, body: body) }
            }
        }
        .confirmationDialog("Delete margin note?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Delete note", role: .destructive) {
                if let note = removing { Task { try? await store.removeMarginNote(note.id) } }
                removing = nil
            }
        } message: { Text("The PDF and its annotations are unchanged.") }
    }
}

private struct ReviewCardDraft: Identifiable {
    let id = UUID()
    let card: WorkspaceReviewCard?
}

struct WorkspaceReviewView: View {
    let store: WorkspaceStore
    let currentPage: Int
    let selection: () -> WorkspaceSelection?
    let onNavigate: (Int, PDFNoteRegion?) -> Void
    @State private var editing: ReviewCardDraft?
    @State private var revealedID: UUID?
    @State private var removing: WorkspaceReviewCard?
    @State private var status: String?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let reviewDate = Date()
            let due = store.dueCards(at: reviewDate)
            List {
                Section {
                    HStack {
                        Button("New card", systemImage: "plus") { editing = ReviewCardDraft(card: nil) }
                        Spacer()
                        Button("From selection", systemImage: "text.quote") {
                            guard let selected = selection(), !selected.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                status = "Select text in the PDF first."
                                return
                            }
                            Task {
                                do {
                                    let count = try await store.addCards(from: selected.quote, pageIndex: selected.pageIndex)
                                    status = "Added \(count) editable source card\(count == 1 ? "" : "s")."
                                } catch { status = error.localizedDescription }
                            }
                        }
                    }.disabled(store.isSaving)
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    Text("Try an answer before revealing the source. Grade your recall to schedule the next review. From selection adds up to 12 passages from the first 120,000 characters.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Due now · \(due.count)") {
                    if let card = due.first {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(card.question).font(.headline).textSelection(.enabled)
                            if revealedID == card.id {
                                Text(card.answer).textSelection(.enabled)
                                if let page = card.pageIndex { Button("Open source · Page \(page + 1)") { onNavigate(page, card.region) } }
                                ViewThatFits(in: .horizontal) {
                                    HStack { gradeButtons(card, at: reviewDate) }
                                    VStack(alignment: .leading) { gradeButtons(card, at: reviewDate) }
                                }
                            } else { Button("Reveal answer", systemImage: "eye") { revealedID = card.id }.paperdeskProminentAction() }
                        }.padding(.vertical, 8)
                    } else {
                        Label(store.cards.isEmpty ? "Add your first card" : "You’re up to date", systemImage: "checkmark.circle")
                        if let next = store.cards.first { Text("Next review \(next.dueAt, style: .relative)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("All cards · \(store.cards.count)") {
                    ForEach(store.cards) { card in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top) {
                                Text(card.question).lineLimit(3)
                                Spacer()
                                Menu {
                                    Button("Edit card") { editing = ReviewCardDraft(card: card) }
                                    if let page = card.pageIndex { Button("Open source") { onNavigate(page, card.region) } }
                                    Button("Delete card", role: .destructive) { removing = card }
                                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Card actions")
                            }
                            Text(card.dueAt <= reviewDate ? "Due now" : "Due \(card.dueAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }
                }
            }
        }
        .sheet(item: $editing) { draft in
            WorkspaceCardSheet(card: draft.card) { question, answer in
                if let card = draft.card { try await store.editCard(card.id, question: question, answer: answer) }
                else { try await store.addCard(question: question, answer: answer, pageIndex: max(0, currentPage)) }
            }
        }
        .confirmationDialog("Delete review card?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Delete card", role: .destructive) {
                if let card = removing { Task { try? await store.removeCard(card.id) } }
                removing = nil
            }
        }
    }
    @ViewBuilder private func gradeButtons(_ card: WorkspaceReviewCard, at date: Date) -> some View {
        ForEach(ReviewGrade.allCases) { grade in
            Button {
                Task {
                    do { try await store.review(cardID: card.id, grade: grade, at: date); revealedID = nil }
                    catch { status = error.localizedDescription }
                }
            } label: {
                VStack(spacing: 2) {
                    Text(grade.title)
                    Text(card.scheduled(grade, at: date).dueAt, style: .relative).font(.caption2)
                }
            }.disabled(store.isSaving)
        }
    }
}

private struct WorkspaceTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let fieldLabel: String
    let initialText: String
    let context: String
    let save: (String) async throws -> Void
    @State private var text: String
    @State private var saving = false
    @State private var error: String?
    init(title: String, initialText: String, fieldLabel: String, context: String = "", save: @escaping (String) async throws -> Void) {
        self.title = title; self.fieldLabel = fieldLabel; self.initialText = initialText; self.context = context; self.save = save
        _text = State(initialValue: initialText)
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if !context.isEmpty { Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(6) }
                Text(fieldLabel).font(.headline)
                TextEditor(text: $text).frame(minHeight: 160).accessibilityLabel(fieldLabel)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }.disabled(saving)
                    Spacer()
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task {
                            do { try await save(text); dismiss() }
                            catch { self.error = error.localizedDescription; saving = false }
                        }
                    }.disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).paperdeskProminentAction()
                }.paperdeskActions()
            }.padding(20).navigationTitle(title)
                .frame(idealWidth: 460, idealHeight: 330)
                .interactiveDismissDisabled(saving || text != initialText)
        }
    }
}

private struct WorkspaceCardSheet: View {
    @Environment(\.dismiss) private var dismiss
    let save: (String, String) async throws -> Void
    let originalQuestion: String
    let originalAnswer: String
    @State private var question: String
    @State private var answer: String
    @State private var saving = false
    @State private var error: String?
    init(card: WorkspaceReviewCard?, save: @escaping (String, String) async throws -> Void) {
        self.save = save
        originalQuestion = card?.question ?? ""; originalAnswer = card?.answer ?? ""
        _question = State(initialValue: card?.question ?? "")
        _answer = State(initialValue: card?.answer ?? "")
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Prompt").font(.headline)
                TextEditor(text: $question).frame(minHeight: 70).accessibilityLabel("Card prompt")
                Text("Answer from the source").font(.headline)
                TextEditor(text: $answer).frame(minHeight: 130).accessibilityLabel("Card answer")
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }.disabled(saving)
                    Spacer()
                    Button(saving ? "Saving…" : "Save card") {
                        saving = true
                        Task {
                            do { try await save(question, answer); dismiss() }
                            catch { self.error = error.localizedDescription; saving = false }
                        }
                    }.disabled(saving || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).paperdeskProminentAction()
                }.paperdeskActions()
            }.padding(20).navigationTitle("Review card")
                .frame(idealWidth: 460, idealHeight: 440)
                .interactiveDismissDisabled(saving || question != originalQuestion || answer != originalAnswer)
        }
    }
}
