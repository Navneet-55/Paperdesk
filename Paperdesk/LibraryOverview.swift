import PDFKit
import SwiftUI

enum LibraryFilter: Hashable {
    case all
    case unfiled
    case collection(String)

    var title: String {
        switch self {
        case .all: "Library"
        case .unfiled: "Unfiled"
        case .collection(let name): name
        }
    }

    func includes(_ document: LibraryDocument) -> Bool {
        switch self {
        case .all: true
        case .unfiled: document.folder == nil
        case .collection(let name): document.folder == name
        }
    }
}

/// Serial rendering bounds peak work to one PDF page. Only small raster data is retained.
actor DocumentCoverCache {
    static let shared = DocumentCoverCache()
    private var cache: [URL: Data] = [:]
    private var recency: [URL] = []
    private let capacity = 32

    func cover(for url: URL) throws -> Data? {
        try Task.checkCancellation()
        if let data = cache[url] {
            recency.removeAll { $0 == url }
            recency.append(url)
            return data
        }
        guard let document = PDFDocument(url: url), !document.isLocked,
            let page = document.page(at: 0)
        else { return nil }
        let thumbnail = page.thumbnail(of: CGSize(width: 280, height: 360), for: .cropBox)
        #if os(macOS)
            let data = thumbnail.tiffRepresentation.flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            }
        #else
            let data = thumbnail.pngData()
        #endif
        try Task.checkCancellation()
        guard let data else { return nil }
        if recency.count >= capacity {
            cache.removeValue(forKey: recency.removeFirst())
        }
        cache[url] = data
        recency.append(url)
        return data
    }

    func invalidate() {
        cache.removeAll()
        recency.removeAll()
    }
}

struct LibraryOverview<Actions: View>: View {
    let documents: [LibraryDocument]
    let directory: URL
    let title: String
    let libraryIsEmpty: Bool
    let importing: Bool
    let onSelect: (UUID) -> Void
    let onImport: () -> Void
    let onSample: () -> Void
    @ViewBuilder let documentActions: (LibraryDocument) -> Actions

    var body: some View {
        List {
            ForEach(documents) { document in
                Button {
                    onSelect(document.id)
                } label: {
                    LibraryDocumentRow(
                        document: document,
                        url: directory.appendingPathComponent(document.filename))
                }
                .buttonStyle(.plain)
                .contextMenu { documentActions(document) }
                .accessibilityHint("Open document")
            }
        }
        .listStyle(.plain)
        .overlay {
            if documents.isEmpty {
                ContentUnavailableView {
                    Label(libraryIsEmpty ? "No documents" : "No matching documents",
                          systemImage: libraryIsEmpty ? "doc" : "magnifyingglass")
                } description: {
                    Text(libraryIsEmpty ? "Import a PDF to start reading." : "Choose another collection or change your search.")
                } actions: {
                    if libraryIsEmpty {
                        Button("Open sample", systemImage: "book", action: onSample)
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Import PDF", systemImage: "plus", action: onImport)
                    .keyboardShortcut("o", modifiers: .command)
                    .help("Copy a PDF into your library")
            }
        }
        .disabled(importing)
    }
}

struct LibraryDocumentRow: View {
    let document: LibraryDocument
    let url: URL

    var body: some View {
        HStack(spacing: 12) {
            DocumentCoverThumbnail(url: url)
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(document.folder ?? "Unfiled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Page \(document.lastPage + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(document.importedAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !document.notes.isEmpty {
                Image(systemName: "note.text")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Has notes")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct DocumentCoverThumbnail: View {
    let url: URL
    @State private var cover: Image?

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            if let cover {
                cover.resizable().scaledToFit()
            } else {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.3))
        }
        .accessibilityHidden(true)
        .task(id: url) {
            cover = nil
            guard let data = try? await DocumentCoverCache.shared.cover(for: url),
                  !Task.isCancelled else { return }
            #if os(macOS)
                if let image = NSImage(data: data) { cover = Image(nsImage: image) }
            #else
                if let image = UIImage(data: data) { cover = Image(uiImage: image) }
            #endif
        }
    }
}
