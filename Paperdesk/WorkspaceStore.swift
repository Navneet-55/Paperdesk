import Foundation
import CoreGraphics
import Observation

struct PDFNoteRegion: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    init(bounds: CGRect) {
        let box = bounds.standardized
        x = box.minX; y = box.minY; width = box.width; height = box.height
    }
    var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

struct WorkspaceSelection: Sendable {
    let pageIndex: Int
    let bounds: CGRect?
    let quote: String
}

struct WorkspaceBookmark: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var pageIndex: Int
    var title: String
    let createdAt: Date
}

struct WorkspaceMarginNote: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var pageIndex: Int
    let region: PDFNoteRegion?
    let quote: String
    var body: String
    let createdAt: Date
    var modifiedAt: Date
    var sourceRemoved: Bool
    init(id: UUID, pageIndex: Int, region: PDFNoteRegion?, quote: String, body: String, createdAt: Date, modifiedAt: Date, sourceRemoved: Bool = false) {
        self.id = id; self.pageIndex = pageIndex; self.region = region; self.quote = quote; self.body = body
        self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.sourceRemoved = sourceRemoved
    }
    private enum CodingKeys: String, CodingKey { case id, pageIndex, region, quote, body, createdAt, modifiedAt, sourceRemoved }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        pageIndex = try values.decode(Int.self, forKey: .pageIndex)
        region = try values.decodeIfPresent(PDFNoteRegion.self, forKey: .region)
        quote = try values.decode(String.self, forKey: .quote)
        body = try values.decode(String.self, forKey: .body)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        sourceRemoved = try values.decodeIfPresent(Bool.self, forKey: .sourceRemoved) ?? false
    }
}

struct WorkspaceCardInput: Sendable {
    let question: String
    let answer: String
    var pageIndex: Int? = nil
    var bounds: CGRect? = nil
}

enum ReviewGrade: String, Codable, CaseIterable, Identifiable, Sendable {
    case again, hard, good, easy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct WorkspaceReviewCard: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var question: String
    var answer: String
    var pageIndex: Int?
    var region: PDFNoteRegion?
    let createdAt: Date
    var dueAt: Date
    var repetitions: Int = 0
    var intervalDays: Double = 0
    var ease: Double = 2.5
    var lapses: Int = 0

    /// A small, deterministic spaced-practice schedule. All dates are absolute;
    /// this avoids day-boundary/time-zone changes unexpectedly resetting a queue.
    func scheduled(_ grade: ReviewGrade, at now: Date) -> Self {
        var next = self
        switch grade {
        case .again:
            next.repetitions = 0
            next.intervalDays = 0
            next.ease = max(1.3, ease - 0.2)
            next.lapses = min(Int.max - 1, lapses + 1)
            next.dueAt = now.addingTimeInterval(10 * 60)
            return next
        case .hard:
            next.intervalDays = intervalDays == 0 ? 0.5 : max(0.5, intervalDays * 1.2)
            next.ease = max(1.3, ease - 0.15)
        case .good:
            next.intervalDays = intervalDays == 0 ? 1 : max(1, intervalDays * ease)
        case .easy:
            next.intervalDays = intervalDays == 0 ? 4 : max(4, intervalDays * ease * 1.3)
            next.ease = min(3.5, ease + 0.15)
        }
        next.intervalDays = min(36_500, next.intervalDays)
        next.repetitions = min(Int.max - 1, repetitions + 1)
        next.dueAt = now.addingTimeInterval(next.intervalDays * 86_400)
        return next
    }
}

struct DocumentWorkspace: Codable, Sendable {
    let version: Int
    let documentID: UUID
    var revision: Int
    var bookmarks: [WorkspaceBookmark]
    var marginNotes: [WorkspaceMarginNote]
    var cards: [WorkspaceReviewCard]
    init(documentID: UUID) {
        version = 1; self.documentID = documentID; revision = 0
        bookmarks = []; marginNotes = []; cards = []
    }
}

private enum WorkspaceChange: Sendable {
    case bookmark(page: Int, title: String, date: Date)
    case deleteBookmark(UUID)
    case addNote(WorkspaceMarginNote)
    case editNote(UUID, String, Date)
    case deleteNote(UUID)
    case addCards([WorkspaceReviewCard])
    case editCard(UUID, String, String)
    case deleteCard(UUID)
    case review(UUID, ReviewGrade, Date)
    case remapPages([Int: Int])
}

private enum WorkspaceError: LocalizedError {
    case invalidData, notLoaded, missingRecord, emptyText
    var errorDescription: String? {
        switch self {
        case .invalidData: return "This document’s workspace could not be read safely. Restore its workspace file from a backup; the existing file has been preserved."
        case .notLoaded: return "Load this document’s workspace before making changes."
        case .missingRecord: return "This item was removed in another window. Reload the workspace to continue."
        case .emptyText: return "Add text before saving."
        }
    }
}

/// Serializes transactions across reader windows. Each change is applied to the
/// newest disk state, so saving one document/window cannot overwrite another.
private actor WorkspaceRepository {
    static let shared = WorkspaceRepository()
    func read(documentID: UUID, url: URL) throws -> DocumentWorkspace {
        guard FileManager.default.fileExists(atPath: url.path) else { return DocumentWorkspace(documentID: documentID) }
        let workspace = try JSONDecoder().decode(DocumentWorkspace.self, from: Data(contentsOf: url))
        guard workspace.version == 1, workspace.documentID == documentID, workspace.revision >= 0, workspace.revision < Int.max,
              Set(workspace.bookmarks.map(\.id)).count == workspace.bookmarks.count,
              Set(workspace.marginNotes.map(\.id)).count == workspace.marginNotes.count,
              Set(workspace.cards.map(\.id)).count == workspace.cards.count,
              workspace.bookmarks.allSatisfy({ $0.pageIndex >= 0 && $0.pageIndex < Int.max }),
              workspace.marginNotes.allSatisfy({ $0.pageIndex >= 0 && $0.pageIndex < Int.max && ($0.region?.isValid ?? true) }),
              workspace.cards.allSatisfy({ ($0.pageIndex ?? 0) >= 0 && ($0.pageIndex ?? 0) < Int.max && ($0.region?.isValid ?? true) && $0.intervalDays.isFinite && $0.intervalDays >= 0 && $0.ease.isFinite && (1.3...3.5).contains($0.ease) && $0.repetitions >= 0 && $0.repetitions < Int.max && $0.lapses >= 0 && $0.lapses < Int.max }) else { throw WorkspaceError.invalidData }
        return workspace
    }
    func apply(_ change: WorkspaceChange, documentID: UUID, url: URL) throws -> DocumentWorkspace {
        var workspace = try read(documentID: documentID, url: url)
        switch change {
        case .bookmark(let page, let title, let date):
            guard page >= 0, page < Int.max else { throw WorkspaceError.invalidData }
            if let index = workspace.bookmarks.firstIndex(where: { $0.pageIndex == page }) { workspace.bookmarks[index].title = title }
            else { workspace.bookmarks.append(WorkspaceBookmark(id: UUID(), pageIndex: page, title: title, createdAt: date)) }
        case .deleteBookmark(let id): workspace.bookmarks.removeAll { $0.id == id }
        case .addNote(let note):
            guard note.pageIndex >= 0, note.pageIndex < Int.max, note.region?.isValid ?? true else { throw WorkspaceError.invalidData }
            workspace.marginNotes.append(note)
        case .editNote(let id, let text, let date):
            guard let index = workspace.marginNotes.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.missingRecord }
            workspace.marginNotes[index].body = text; workspace.marginNotes[index].modifiedAt = date
        case .deleteNote(let id): workspace.marginNotes.removeAll { $0.id == id }
        case .addCards(let cards):
            guard cards.allSatisfy({ ($0.pageIndex ?? 0) >= 0 && ($0.pageIndex ?? 0) < Int.max && ($0.region?.isValid ?? true) }) else { throw WorkspaceError.invalidData }
            workspace.cards.append(contentsOf: cards)
        case .editCard(let id, let question, let answer):
            guard let index = workspace.cards.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.missingRecord }
            workspace.cards[index].question = question; workspace.cards[index].answer = answer
        case .deleteCard(let id): workspace.cards.removeAll { $0.id == id }
        case .review(let id, let grade, let date):
            guard let index = workspace.cards.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.missingRecord }
            workspace.cards[index] = workspace.cards[index].scheduled(grade, at: date)
        case .remapPages(let mapping):
            guard mapping.allSatisfy({ $0.key >= 0 && $0.key < Int.max && $0.value >= 0 && $0.value < Int.max }), Set(mapping.values).count == mapping.count else { throw WorkspaceError.invalidData }
            workspace.bookmarks = workspace.bookmarks.compactMap { bookmark in
                guard let page = mapping[bookmark.pageIndex] else { return nil }
                var moved = bookmark; moved.pageIndex = page; return moved
            }
            for index in workspace.marginNotes.indices where !workspace.marginNotes[index].sourceRemoved {
                if let page = mapping[workspace.marginNotes[index].pageIndex] { workspace.marginNotes[index].pageIndex = page }
                else { workspace.marginNotes[index].sourceRemoved = true }
            }
            for index in workspace.cards.indices {
                guard let oldPage = workspace.cards[index].pageIndex else { continue }
                workspace.cards[index].pageIndex = mapping[oldPage]
                if workspace.cards[index].pageIndex == nil { workspace.cards[index].region = nil }
            }
        }
        workspace.revision += 1
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(workspace).write(to: url, options: .atomic)
        return workspace
    }
}

@MainActor @Observable final class WorkspaceStore {
    let documentID: UUID
    let url: URL
    private(set) var workspace: DocumentWorkspace
    private(set) var isLoaded = false
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var saveStatus = "Loading…"
    var error: String?
    private var pendingWrites = 0
    init(documentID: UUID, directory: URL) {
        self.documentID = documentID
        url = directory.appendingPathComponent("\(documentID).workspace.json")
        workspace = DocumentWorkspace(documentID: documentID)
    }
    var bookmarks: [WorkspaceBookmark] { workspace.bookmarks.sorted { $0.pageIndex < $1.pageIndex } }
    var marginNotes: [WorkspaceMarginNote] { workspace.marginNotes.sorted { $0.createdAt > $1.createdAt } }
    var cards: [WorkspaceReviewCard] { workspace.cards.sorted { $0.dueAt < $1.dueAt } }
    func dueCards(at date: Date = Date()) -> [WorkspaceReviewCard] { cards.filter { $0.dueAt <= date } }
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await WorkspaceRepository.shared.read(documentID: documentID, url: url)
            if loaded.revision >= workspace.revision { workspace = loaded }
            isLoaded = true; saveStatus = "Saved locally"; error = nil
        } catch {
            isLoaded = false; saveStatus = "Could not load"
            self.error = "Could not load bookmarks, margin notes and review cards: \(error.localizedDescription)"
        }
    }
    func bookmark(pageIndex: Int, title: String = "") async throws {
        guard pageIndex >= 0, pageIndex < Int.max else { throw WorkspaceError.invalidData }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try await apply(.bookmark(page: pageIndex, title: cleaned.isEmpty ? "Page \(pageIndex + 1)" : cleaned, date: Date()))
    }
    func removeBookmark(_ id: UUID) async throws { try await apply(.deleteBookmark(id)) }
    func addMarginNote(pageIndex: Int, bounds: CGRect? = nil, quote: String = "", body: String) async throws {
        let text = try cleaned(body)
        let now = Date()
        try await apply(.addNote(WorkspaceMarginNote(id: UUID(), pageIndex: pageIndex, region: bounds.map(PDFNoteRegion.init(bounds:)), quote: quote, body: text, createdAt: now, modifiedAt: now)))
    }
    func editMarginNote(_ id: UUID, body: String) async throws { try await apply(.editNote(id, try cleaned(body), Date())) }
    func removeMarginNote(_ id: UUID) async throws { try await apply(.deleteNote(id)) }
    func addCard(question: String, answer: String, pageIndex: Int? = nil, bounds: CGRect? = nil) async throws {
        let now = Date()
        try await apply(.addCards([WorkspaceReviewCard(id: UUID(), question: try cleaned(question), answer: try cleaned(answer), pageIndex: pageIndex, region: bounds.map(PDFNoteRegion.init(bounds:)), createdAt: now, dueAt: now)]))
    }
    /// Makes editable cloze-style prompts from source passages, without generating
    /// ungrounded answers. Up to 12 paragraphs from the first 120,000 characters
    /// are added per deliberate action, keeping huge selections responsive.
    @discardableResult func addCards(from text: String, pageIndex: Int? = nil) async throws -> Int {
        let text = try cleaned(String(text.prefix(120_000)))
        let passages = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(12)
        let now = Date()
        let cards = passages.map { passage in
            let words = passage.split(whereSeparator: \.isWhitespace)
            let opening = words.prefix(min(6, max(1, words.count / 2))).joined(separator: " ")
            return WorkspaceReviewCard(id: UUID(), question: "Complete the passage: \(opening)…", answer: passage, pageIndex: pageIndex, region: nil, createdAt: now, dueAt: now)
        }
        try await apply(.addCards(cards))
        return cards.count
    }
    /// Bulk import uses a single transaction, including material prepared by Offline Study.
    @discardableResult func addCards(_ inputs: [WorkspaceCardInput]) async throws -> Int {
        guard !inputs.isEmpty else { return 0 }
        let now = Date()
        let cards = try inputs.map { input in
            WorkspaceReviewCard(id: UUID(), question: try cleaned(input.question), answer: try cleaned(input.answer), pageIndex: input.pageIndex, region: input.bounds.map(PDFNoteRegion.init(bounds:)), createdAt: now, dueAt: now)
        }
        try await apply(.addCards(cards))
        return cards.count
    }
    /// Mapping includes every surviving original page; missing pages were removed.
    /// Notes and card answers survive removal, but cannot jump to an unrelated page.
    func remapPages(originalToNew: [Int: Int]) async throws { try await apply(.remapPages(originalToNew)) }
    func editCard(_ id: UUID, question: String, answer: String) async throws { try await apply(.editCard(id, try cleaned(question), try cleaned(answer))) }
    func removeCard(_ id: UUID) async throws { try await apply(.deleteCard(id)) }
    func review(cardID: UUID, grade: ReviewGrade, at date: Date = Date()) async throws { try await apply(.review(cardID, grade, date)) }
    private func cleaned(_ text: String) throws -> String {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw WorkspaceError.emptyText }
        return result
    }
    private func apply(_ change: WorkspaceChange) async throws {
        guard isLoaded else { throw WorkspaceError.notLoaded }
        pendingWrites += 1; isSaving = true; saveStatus = "Saving…"
        defer { pendingWrites -= 1; isSaving = pendingWrites > 0 }
        do {
            let saved = try await WorkspaceRepository.shared.apply(change, documentID: documentID, url: url)
            if saved.revision >= workspace.revision { workspace = saved }
            saveStatus = pendingWrites > 1 ? "Saving…" : "Saved locally"
            self.error = nil
        } catch {
            saveStatus = "Not saved"
            self.error = "Changes could not be saved. Your saved workspace was preserved. \(error.localizedDescription)"
            throw error
        }
    }
}
