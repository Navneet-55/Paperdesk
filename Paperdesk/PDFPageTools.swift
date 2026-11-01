import Foundation
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct PDFPageToolsRow: Identifiable, Sendable {
    let id: Int
    let sourceURL: URL?
    let sourceIndex: Int?
    var rotationDelta = 0
    var label: String
}

struct PDFPageToolsSession: Sendable {
    let snapshot: PDFFileSnapshot
    let rows: [PDFPageToolsRow]
    let restriction: PDFPageToolsError?
    var version: PDFFileVersion { snapshot.version }
}

struct PDFPageMergeSource: Sendable {
    let snapshot: PDFFileSnapshot
    let pageCount: Int
    let name: String
}

enum PDFPageOperation: Sendable {
    case rotate(indices: [Int], clockwiseDegrees: Int)
    /// Destination is the final index after removing the source page.
    case move(from: Int, to: Int)
    case duplicate(index: Int)
    case insertBlank(at: Int)
    case delete(indices: [Int])
    case merge(PDFPageMergeSource)
}

struct PDFPageToolsResult: Sendable {
    let version: PDFFileVersion
    let pageCount: Int
    /// Original zero-based page indices mapped to their first surviving location.
    let originalToNew: [Int: Int]
}

final class PDFPageExport: @unchecked Sendable {
    let directory: URL
    let url: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Paperdesk-pages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("Selected pages.pdf")
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum PDFPageToolsError: LocalizedError, Sendable {
    case invalidPage, emptyDocument, unreadable, protectedDocument, signature, serialization
    var errorDescription: String? {
        switch self {
        case .invalidPage: "A selected page is no longer available. Reopen page tools and try again."
        case .emptyDocument: "Keep at least one page in the document."
        case .unreadable: "This PDF could not be opened for page management."
        case .protectedDocument: "Page management is unavailable for encrypted or restricted PDFs. Export an unrestricted copy from the source application first."
        case .signature: "This PDF has a signature field or digital signature. Page changes and splitting can invalidate signatures, so Paperdesk leaves this document unchanged. Use the signing application to create an unsigned working copy."
        case .serialization: "The new PDF could not be written. The library original is unchanged."
        }
    }
}

/// All structural writes share the same actor as annotation saves. Each operation works on
/// an immutable snapshot and only replaces the library file after a final version check.
extension PDFWriteService {
    func openPageTools(url: URL, expectedVersion: PDFFileVersion) throws -> PDFPageToolsSession {
        let snapshot = try pageToolsSnapshot(url: url, expectedVersion: expectedVersion)
        guard let document = PDFDocument(url: snapshot.url), document.pageCount > 0 else { throw PDFPageToolsError.unreadable }
        let restriction = try pageToolsRestriction(document: document, url: snapshot.url)
        let rows = (0..<document.pageCount).map {
            PDFPageToolsRow(id: $0, sourceURL: snapshot.url, sourceIndex: $0, label: "Page \($0 + 1)")
        }
        return PDFPageToolsSession(snapshot: snapshot, rows: rows, restriction: restriction)
    }

    func stagePageMerge(urls: [URL]) throws -> [PDFPageMergeSource] {
        try urls.map { url in
            try Task.checkCancellation()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let snapshot = try PDFFileSnapshot(copying: url)
            guard let document = PDFDocument(url: snapshot.url), document.pageCount > 0 else { throw PDFPageToolsError.unreadable }
            if let restriction = try pageToolsRestriction(document: document, url: snapshot.url) { throw restriction }
            return PDFPageMergeSource(snapshot: snapshot, pageCount: document.pageCount, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    /// Only small descriptors are materialized here, never PDFPage objects or images on main.
    func pageToolsRows(session: PDFPageToolsSession, operations: [PDFPageOperation]) throws -> [PDFPageToolsRow] {
        var rows = session.rows
        var nextID = rows.count
        func valid(_ index: Int) throws {
            guard rows.indices.contains(index) else { throw PDFPageToolsError.invalidPage }
        }
        for operation in operations {
            try Task.checkCancellation()
            switch operation {
            case .rotate(let indices, let degrees):
                guard degrees.isMultiple(of: 90) else { throw PDFPageToolsError.invalidPage }
                for index in Set(indices) { try valid(index); rows[index].rotationDelta = (rows[index].rotationDelta + degrees) % 360 }
            case .move(let from, let to):
                try valid(from); try valid(to)
                let row = rows.remove(at: from); rows.insert(row, at: to)
            case .duplicate(let index):
                try valid(index)
                let original = rows[index]
                let copied = PDFPageToolsRow(id: nextID, sourceURL: original.sourceURL, sourceIndex: original.sourceIndex, rotationDelta: original.rotationDelta, label: original.label + " copy")
                nextID += 1; rows.insert(copied, at: index + 1)
            case .insertBlank(let index):
                guard index >= 0, index <= rows.count else { throw PDFPageToolsError.invalidPage }
                rows.insert(PDFPageToolsRow(id: nextID, sourceURL: nil, sourceIndex: nil, label: "Blank page"), at: index); nextID += 1
            case .delete(let indices):
                let indices = Set(indices).sorted(by: >)
                guard indices.count < rows.count else { throw PDFPageToolsError.emptyDocument }
                for index in indices { try valid(index) }
                for index in indices { rows.remove(at: index) }
            case .merge(let imported):
                for index in 0..<imported.pageCount {
                    if index.isMultiple(of: 128) { try Task.checkCancellation() }
                    rows.append(PDFPageToolsRow(id: nextID, sourceURL: imported.snapshot.url, sourceIndex: index, label: "\(imported.name) · \(index + 1)")); nextID += 1
                }
            }
        }
        return rows
    }

    func applyPageOperations(url: URL, expectedVersion: PDFFileVersion, operations: [PDFPageOperation]) throws -> PDFPageToolsResult {
        let session = try openPageTools(url: url, expectedVersion: expectedVersion)
        if let restriction = session.restriction { throw restriction }
        let rows = try pageToolsRows(session: session, operations: operations)
        guard !rows.isEmpty else { throw PDFPageToolsError.emptyDocument }
        if operations.isEmpty {
            return PDFPageToolsResult(version: expectedVersion, pageCount: rows.count, originalToNew: Dictionary(uniqueKeysWithValues: rows.indices.map { ($0, $0) }))
        }
        let working = try pageToolsWorkingCopy(session: session, operations: operations)
        try Task.checkCancellation()
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".Paperdesk-pages-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        defer { withExtendedLifetime(working) {} }
        guard working.document.write(to: temporary), let verification = PDFDocument(url: temporary), verification.pageCount == rows.count else { throw PDFPageToolsError.serialization }
        let version = try PDFFileVersion.read(from: temporary)
        try Task.checkCancellation()
        guard try PDFFileVersion.read(from: url) == expectedVersion else { throw PDFSaveError.conflict }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        var map: [Int: Int] = [:]
        for (newIndex, row) in rows.enumerated() where row.sourceURL == session.snapshot.url {
            if let oldIndex = row.sourceIndex, map[oldIndex] == nil { map[oldIndex] = newIndex }
        }
        return PDFPageToolsResult(version: version, pageCount: rows.count, originalToNew: map)
    }

    /// Exports a derived file only. The library PDF is never modified by splitting.
    func exportPageSelection(url: URL, expectedVersion: PDFFileVersion, operations: [PDFPageOperation] = [], indices: [Int]) throws -> PDFPageExport {
        let session = try openPageTools(url: url, expectedVersion: expectedVersion)
        if let restriction = session.restriction { throw restriction }
        let working = try pageToolsWorkingCopy(session: session, operations: operations)
        let selected = Array(Set(indices)).sorted()
        guard !selected.isEmpty else { throw PDFPageToolsError.emptyDocument }
        guard selected.allSatisfy({ $0 >= 0 && $0 < working.document.pageCount }) else { throw PDFPageToolsError.invalidPage }
        let output = PDFDocument()
        output.documentAttributes = working.document.documentAttributes
        var originals: [PDFPage] = []
        var copies: [PDFPage] = []
        var map: [Int: PDFPage] = [:]
        for index in selected {
            try Task.checkCancellation()
            guard let original = working.document.page(at: index), let copied = original.copy() as? PDFPage else { throw PDFPageToolsError.unreadable }
            originals.append(original); copies.append(copied); map[index] = copied
            output.insert(copied, at: output.pageCount)
        }
        retargetPageToolsLinks(pages: copies, source: working.document, pageMap: map)
        if let outline = working.document.outlineRoot { output.outlineRoot = copyPageToolsOutline(outline, source: working.document, pageMap: map, isRoot: true) }
        let exported = try PDFPageExport()
        defer { withExtendedLifetime(working) {}; withExtendedLifetime(originals) {}; withExtendedLifetime(copies) {} }
        try Task.checkCancellation()
        guard output.write(to: exported.url), let verification = PDFDocument(url: exported.url), verification.pageCount == selected.count else { throw PDFPageToolsError.serialization }
        try Task.checkCancellation()
        guard try PDFFileVersion.read(from: url) == expectedVersion else { throw PDFSaveError.conflict }
        return exported
    }

    private func pageToolsSnapshot(url: URL, expectedVersion: PDFFileVersion) throws -> PDFFileSnapshot {
        guard try PDFFileVersion.read(from: url) == expectedVersion else { throw PDFSaveError.conflict }
        let snapshot = try PDFFileSnapshot(copying: url)
        guard snapshot.version == expectedVersion else { throw PDFSaveError.conflict }
        return snapshot
    }

    private func pageToolsRestriction(document: PDFDocument, url: URL) throws -> PDFPageToolsError? {
        if document.isLocked || document.isEncrypted || !document.allowsDocumentAssembly { return .protectedDocument }
        for index in 0..<document.pageCount {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            let hasSignature = autoreleasepool {
                document.page(at: index)?.annotations.contains {
                    $0.type?.lowercased() == "widget" && $0.widgetFieldType == .signature
                } ?? false
            }
            if hasSignature { return .signature }
        }
        // Signature dictionaries may be hidden from the page's annotation list. Inspect
        // bounded chunks, including overlap, rather than loading a huge PDF into memory.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var suffix = Data()
        let marker = Data("/ByteRange".utf8)
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            var chunk = suffix; chunk.append(data)
            if chunk.range(of: marker) != nil { return .signature }
            suffix = chunk.suffix(marker.count - 1)
        }
        return nil
    }

    private final class PageToolsWorkingCopy {
        let snapshot: PDFFileSnapshot
        let document: PDFDocument
        var owners: [PDFDocument] = []
        var importedSnapshots: [PDFFileSnapshot] = []
        var retainedPages: [PDFPage] = []
        init(snapshot: PDFFileSnapshot, document: PDFDocument) { self.snapshot = snapshot; self.document = document }
    }

    private func pageToolsWorkingCopy(session: PDFPageToolsSession, operations: [PDFPageOperation]) throws -> PageToolsWorkingCopy {
        guard let document = PDFDocument(url: session.snapshot.url) else { throw PDFPageToolsError.unreadable }
        let working = PageToolsWorkingCopy(snapshot: session.snapshot, document: document)
        var removedPages = false
        func page(_ index: Int) throws -> PDFPage {
            guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { throw PDFPageToolsError.invalidPage }
            return page
        }
        for operation in operations {
            try Task.checkCancellation()
            switch operation {
            case .rotate(let indices, let degrees):
                guard degrees.isMultiple(of: 90) else { throw PDFPageToolsError.invalidPage }
                for index in Set(indices) {
                    let target = try page(index); target.rotation = (target.rotation + degrees) % 360
                    working.retainedPages.append(target)
                    document.removePage(at: index); document.insert(target, at: index)
                }
            case .move(let from, let to):
                _ = try page(to)
                let target = try page(from); working.retainedPages.append(target)
                document.removePage(at: from); document.insert(target, at: to)
            case .duplicate(let index):
                let original = try page(index)
                guard let copied = original.copy() as? PDFPage else { throw PDFPageToolsError.unreadable }
                working.retainedPages.append(contentsOf: [original, copied]); document.insert(copied, at: index + 1)
            case .insertBlank(let index):
                guard index >= 0, index <= document.pageCount else { throw PDFPageToolsError.invalidPage }
                var box = CGRect(x: 0, y: 0, width: 612, height: 792)
                if document.pageCount > 0 {
                    let reference = try page(min(index, document.pageCount - 1))
                    let bounds = reference.bounds(for: .cropBox)
                    let rotated = abs(reference.rotation % 180) == 90
                    box.size = CGSize(width: rotated ? bounds.height : bounds.width, height: rotated ? bounds.width : bounds.height)
                }
                let data = NSMutableData()
                guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PDFPageToolsError.serialization }
                context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
                guard let owner = PDFDocument(data: data as Data), let blank = owner.page(at: 0)?.copy() as? PDFPage else { throw PDFPageToolsError.serialization }
                working.owners.append(owner); working.retainedPages.append(blank); document.insert(blank, at: index)
            case .delete(let indices):
                let indices = Set(indices).sorted(by: >)
                guard indices.count < document.pageCount else { throw PDFPageToolsError.emptyDocument }
                for index in indices { _ = try page(index) }
                for index in indices { document.removePage(at: index) }
                removedPages = removedPages || !indices.isEmpty
            case .merge(let imported):
                guard let owner = PDFDocument(url: imported.snapshot.url), owner.pageCount == imported.pageCount else { throw PDFPageToolsError.unreadable }
                working.owners.append(owner); working.importedSnapshots.append(imported.snapshot)
                var copies: [PDFPage] = [], originals: [PDFPage] = [], map: [Int: PDFPage] = [:]
                for index in 0..<owner.pageCount {
                    if index.isMultiple(of: 32) { try Task.checkCancellation() }
                    guard let original = owner.page(at: index), let copied = original.copy() as? PDFPage else { throw PDFPageToolsError.unreadable }
                    originals.append(original); copies.append(copied); map[index] = copied; document.insert(copied, at: document.pageCount)
                }
                working.retainedPages.append(contentsOf: originals); working.retainedPages.append(contentsOf: copies)
                retargetPageToolsLinks(pages: copies, source: owner, pageMap: map)
                if let sourceOutline = owner.outlineRoot, let importedOutline = copyPageToolsOutline(sourceOutline, source: owner, pageMap: map, isRoot: true), importedOutline.numberOfChildren > 0 {
                    let root = document.outlineRoot ?? PDFOutline(); document.outlineRoot = root
                    importedOutline.label = imported.name; root.insertChild(importedOutline, at: root.numberOfChildren)
                }
            }
        }
        guard document.pageCount > 0 else { throw PDFPageToolsError.emptyDocument }
        cleanPageToolsOutline(document.outlineRoot, document: document)
        if removedPages { try cleanPageToolsDeletedLinks(working) }
        return working
    }

    private func retargetPageToolsLinks(pages: [PDFPage], source: PDFDocument, pageMap: [Int: PDFPage]) {
        for page in pages {
            for annotation in page.annotations where annotation.type?.lowercased() == "link" {
                guard let destination = annotation.destination, let target = destination.page else { continue }
                let oldIndex = source.index(for: target)
                if let mapped = pageMap[oldIndex] {
                    let replacement = PDFDestination(page: mapped, at: destination.point); replacement.zoom = destination.zoom
                    annotation.destination = replacement
                } else if annotation.type?.lowercased() == "link" { page.removeAnnotation(annotation) }
            }
        }
    }

    private func cleanPageToolsDeletedLinks(_ working: PageToolsWorkingCopy) throws {
        for index in 0..<working.document.pageCount {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            guard let page = working.document.page(at: index) else { continue }
            let orphaned = page.annotations.filter {
                guard $0.type?.lowercased() == "link", let destination = $0.destination, let target = destination.page else { return false }
                return working.document.index(for: target) == NSNotFound
            }
            guard !orphaned.isEmpty else { continue }
            orphaned.forEach { page.removeAnnotation($0) }
            working.retainedPages.append(page)
            working.document.removePage(at: index); working.document.insert(page, at: index)
        }
    }

    private func copyPageToolsOutline(_ sourceOutline: PDFOutline, source: PDFDocument, pageMap: [Int: PDFPage], isRoot: Bool) -> PDFOutline? {
        let copy = PDFOutline(); copy.label = sourceOutline.label; copy.isOpen = sourceOutline.isOpen
        if let destination = sourceOutline.destination, let target = destination.page {
            if let mapped = pageMap[source.index(for: target)] {
                let replacement = PDFDestination(page: mapped, at: destination.point); replacement.zoom = destination.zoom
                copy.destination = replacement
            }
        } else { copy.action = sourceOutline.action }
        for index in 0..<sourceOutline.numberOfChildren {
            if let child = sourceOutline.child(at: index), let copied = copyPageToolsOutline(child, source: source, pageMap: pageMap, isRoot: false) { copy.insertChild(copied, at: copy.numberOfChildren) }
        }
        return isRoot || copy.destination != nil || copy.action != nil || copy.numberOfChildren > 0 ? copy : nil
    }

    private func cleanPageToolsOutline(_ outline: PDFOutline?, document: PDFDocument) {
        guard let outline else { return }
        for index in (0..<outline.numberOfChildren).reversed() {
            guard let child = outline.child(at: index) else { continue }
            cleanPageToolsOutline(child, document: document)
            if let destination = child.destination, let page = destination.page, document.index(for: page) == NSNotFound {
                if child.numberOfChildren == 0 { child.removeFromParent() } else { child.action = nil }
            }
        }
    }
}

/// Serial, bounded thumbnails. No rendering in SwiftUI body and no eager 10k-page raster cache.
actor PDFPageToolsThumbnailCache {
    static let shared = PDFPageToolsThumbnailCache()
    private struct Key: Hashable { let url: URL; let index: Int; let rotation: Int }
    private var images: [Key: Data] = [:]
    private var recency: [Key] = []
    private var document: PDFDocument?
    private var documentURL: URL?
    func label(url: URL, index: Int) -> String? {
        if documentURL != url { document = PDFDocument(url: url); documentURL = url }
        return document?.page(at: index)?.label
    }
    func thumbnail(row: PDFPageToolsRow) throws -> Data? {
        try Task.checkCancellation()
        guard let url = row.sourceURL, let index = row.sourceIndex else { return nil }
        let key = Key(url: url, index: index, rotation: row.rotationDelta)
        if let image = images[key] {
            recency.removeAll { $0 == key }; recency.append(key); return image
        }
        if documentURL != url { document = PDFDocument(url: url); documentURL = url }
        guard let document, index >= 0, index < document.pageCount, let page = document.page(at: index)?.copy() as? PDFPage else { return nil }
        page.rotation = (page.rotation + row.rotationDelta) % 360
        let image = page.thumbnail(of: CGSize(width: 96, height: 120), for: .cropBox)
        #if os(macOS)
        let data = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        #else
        let data = image.pngData()
        #endif
        try Task.checkCancellation()
        guard let data else { return nil }
        if recency.count >= 32 { images.removeValue(forKey: recency.removeFirst()) }
        images[key] = data; recency.append(key)
        return data
    }
}
