import ObjectiveC
import Observation
import PDFKit
import SwiftUI

@MainActor private var pdfEditingOwnerKey: UInt8 = 0
#if os(macOS)
    import AppKit
    private typealias EditingColor = NSColor
    private typealias EditingPath = NSBezierPath
#else
    import UIKit
    import PencilKit
    private typealias EditingColor = UIColor
    private typealias EditingPath = UIBezierPath
#endif

/// Maps the visible crop box (including page rotation) to a top-left-origin canvas.
/// PDF annotations remain in unrotated PDF page coordinates, never screen coordinates.
struct PDFPageGeometry {
    let cropBounds: CGRect
    let pageToDisplay: CGAffineTransform
    let displayBounds: CGRect
    init(page: PDFPage) {
        cropBounds = page.bounds(for: .cropBox)
        pageToDisplay = page.transform(for: .cropBox)
        displayBounds = cropBounds.applying(pageToDisplay)
    }
    var aspectRatio: CGFloat { max(1, displayBounds.width) / max(1, displayBounds.height) }
    func pdfPoint(fromCanvas point: CGPoint, canvasSize: CGSize) -> CGPoint {
        let x = point.x / max(1, canvasSize.width) * displayBounds.width + displayBounds.minX
        let y = (1 - point.y / max(1, canvasSize.height)) * displayBounds.height + displayBounds.minY
        return CGPoint(x: x, y: y).applying(pageToDisplay.inverted())
    }
    func canvasPoint(fromPDF point: CGPoint, canvasSize: CGSize) -> CGPoint {
        let display = point.applying(pageToDisplay)
        return CGPoint(
            x: (display.x - displayBounds.minX) / max(1, displayBounds.width) * canvasSize.width,
            y: (1 - (display.y - displayBounds.minY) / max(1, displayBounds.height)) * canvasSize.height)
    }
    func canvasRect(fromPDF rect: CGRect, canvasSize: CGSize) -> CGRect {
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY),
        ].map { canvasPoint(fromPDF: $0, canvasSize: canvasSize) }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(
            x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }
    func pdfWidth(fromCanvas width: CGFloat, canvasSize: CGSize) -> CGFloat {
        max(0.25, width * displayBounds.width / max(1, canvasSize.width))
    }
}

enum PDFInkAnnotation {
    static func make(points: [CGPoint], width: CGFloat, color: Color, bounds: CGRect) throws -> PDFAnnotation
    {
        let crop = bounds
        let points = points.filter { $0.x.isFinite && $0.y.isFinite }.map {
            CGPoint(x: min(crop.maxX, max(crop.minX, $0.x)), y: min(crop.maxY, max(crop.minY, $0.y)))
        }
        guard !points.isEmpty else { throw PDFEditingFailure.invalidStroke }
        let padding = max(0.25, width / 2)
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let rect = CGRect(
            x: (xs.min() ?? 0) - padding, y: (ys.min() ?? 0) - padding,
            width: max(1, (xs.max() ?? 0) - (xs.min() ?? 0)) + padding * 2,
            height: max(1, (ys.max() ?? 0) - (ys.min() ?? 0)) + padding * 2)
        let annotation = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
        annotation.color = EditingColor(color)
        annotation.userName = "Paperdesk"
        let border = PDFBorder()
        border.lineWidth = max(0.25, width)
        annotation.border = border
        let path = EditingPath()
        let first = CGPoint(x: points[0].x - rect.minX, y: points[0].y - rect.minY)
        path.move(to: first)
        for point in points.dropFirst() {
            let local = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
            #if os(macOS)
                path.line(to: local)
            #else
                path.addLine(to: local)
            #endif
        }
        if points.count == 1 || points.dropFirst().allSatisfy({ $0 == points[0] }) {
            #if os(macOS)
                path.line(to: CGPoint(x: first.x + 0.1, y: first.y + 0.1))
            #else
                path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y + 0.1))
            #endif
        }
        annotation.add(path)
        return annotation
    }
}

enum PDFEditingFailure: LocalizedError {
    case unreadablePage, saveFailed, invalidStroke
    var errorDescription: String? {
        switch self {
        case .unreadablePage: "This page could not be copied for editing."
        case .saveFailed: "The edited PDF page could not be saved."
        case .invalidStroke: "Draw inside the page before adding ink."
        }
    }
}

/// All edits happen on an isolated one-page document. The source stays unchanged until commit.
@MainActor @Observable final class PDFAnnotationEditorModel {
    private(set) var draft: PDFDocument
    private(set) var revision = 0
    private var undoPages: [Data] = []
    private var redoPages: [Data] = []
    private(set) var changed = false
    var page: PDFPage { draft.page(at: 0)! }
    var geometry: PDFPageGeometry { PDFPageGeometry(page: page) }
    var canUndo: Bool { !undoPages.isEmpty }
    var canRedo: Bool { !redoPages.isEmpty }
    nonisolated static let editableTypes: Set<String> = [
        "ink", "highlight", "underline", "strikeout", "freetext", "text", "square", "circle", "line",
    ]
    nonisolated static func isEditable(_ annotation: PDFAnnotation) -> Bool {
        let type = (annotation.type ?? "").lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
        return editableTypes.contains(type)
    }
    var editableAnnotations: [(index: Int, annotation: PDFAnnotation)] {
        page.annotations.enumerated().compactMap { index, annotation in
            Self.isEditable(annotation) ? (index, annotation) : nil
        }
    }
    init(page: PDFPage) throws {
        guard let data = page.dataRepresentation, let copy = PDFDocument(data: data), copy.pageCount == 1
        else { throw PDFEditingFailure.unreadablePage }
        draft = copy
    }
    private func mutate(_ operation: () -> Void) throws {
        guard let previous = page.dataRepresentation else { throw PDFEditingFailure.saveFailed }
        operation()
        undoPages.append(previous)
        while undoPages.count > 1
            && (undoPages.count > 40 || undoPages.reduce(0, { $0 + $1.count }) > 24 * 1024 * 1024)
        { undoPages.removeFirst() }
        redoPages.removeAll()
        changed = true
        revision += 1
    }
    func undo() throws {
        guard let last = undoPages.last, let current = page.dataRepresentation,
            let copy = PDFDocument(data: last), copy.pageCount == 1
        else { return }
        undoPages.removeLast()
        redoPages.append(current)
        draft = copy
        changed = true
        revision += 1
    }
    func redo() throws {
        guard let last = redoPages.last, let current = page.dataRepresentation,
            let copy = PDFDocument(data: last), copy.pageCount == 1
        else { return }
        redoPages.removeLast()
        undoPages.append(current)
        draft = copy
        changed = true
        revision += 1
    }
    /// Points are in PDF page space; paths stored relative to annotation.bounds.origin per PDFKit.
    func addInk(points: [CGPoint], width: CGFloat, color: Color) throws {
        let annotation = try PDFInkAnnotation.make(
            points: points, width: width, color: color, bounds: geometry.cropBounds)
        try mutate { page.addAnnotation(annotation) }
    }

    func addText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let box = geometry.cropBounds
        let rect = CGRect(
            x: box.midX - min(180, box.width * 0.6) / 2, y: box.midY - 24, width: min(180, box.width * 0.6),
            height: min(70, box.height * 0.3))
        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.color = .clear
        annotation.fontColor = .black
        #if os(macOS)
            annotation.font = .systemFont(ofSize: 14)
        #else
            annotation.font = .systemFont(ofSize: 14)
        #endif
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        try mutate { page.addAnnotation(annotation) }
    }
    func remove(index: Int) throws {
        guard page.annotations.indices.contains(index) else { return }
        let annotation = page.annotations[index]
        try mutate { page.removeAnnotation(annotation) }
    }
    func recolor(index: Int, color: Color) throws {
        guard page.annotations.indices.contains(index) else { return }
        let annotation = page.annotations[index]
        try mutate {
            let type = (annotation.type ?? "").lowercased()
            if type == "freetext" {
                annotation.fontColor = EditingColor(color)
            } else {
                annotation.color = EditingColor(color).withAlphaComponent(type == "highlight" ? 0.45 : 1)
            }
        }
    }
    func setText(index: Int, text: String) throws {
        guard page.annotations.indices.contains(index) else { return }
        let annotation = page.annotations[index]
        try mutate { annotation.contents = text }
    }
    func transform(index: Int, newBounds: CGRect) throws {
        guard page.annotations.indices.contains(index), newBounds.width >= 1, newBounds.height >= 1 else {
            return
        }
        let annotation = page.annotations[index]
        let old = annotation.bounds
        guard old.width > 0, old.height > 0 else { return }
        let sx = newBounds.width / old.width
        let sy = newBounds.height / old.height
        try mutate {
            // PDFKit's ink paths and markup quadrilaterals use annotation-local coordinates.
            // Moving changes only bounds.origin; resizing scales local vectors as well as bounds.
            for oldPath in (annotation.type ?? "").lowercased() == "ink" ? (annotation.paths ?? []) : [] {
                let path = oldPath.copy() as! EditingPath
                #if os(macOS)
                    path.transform(using: AffineTransform(m11: sx, m12: 0, m21: 0, m22: sy, tX: 0, tY: 0))
                #else
                    path.apply(CGAffineTransform(scaleX: sx, y: sy))
                #endif
                annotation.remove(oldPath)
                annotation.add(path)
            }
            if ["highlight", "underline", "strikeout"].contains((annotation.type ?? "").lowercased()),
                let quads = annotation.quadrilateralPoints
            {
                annotation.quadrilateralPoints = quads.map {
                    #if os(macOS)
                        let p = $0.pointValue
                        return NSValue(point: CGPoint(x: p.x * sx, y: p.y * sy))
                    #else
                        let p = $0.cgPointValue
                        return NSValue(cgPoint: CGPoint(x: p.x * sx, y: p.y * sy))
                    #endif
                }
            }
            if (annotation.type ?? "").lowercased() == "line" {
                annotation.startPoint = CGPoint(
                    x: annotation.startPoint.x * sx, y: annotation.startPoint.y * sy)
                annotation.endPoint = CGPoint(x: annotation.endPoint.x * sx, y: annotation.endPoint.y * sy)
            }
            annotation.bounds = newBounds
        }
    }
    func move(index: Int, displayDX: CGFloat, displayDY: CGFloat) throws {
        guard page.annotations.indices.contains(index) else { return }
        let inverse = geometry.pageToDisplay.inverted()
        let zero = CGPoint.zero.applying(inverse)
        let delta = CGPoint(x: displayDX, y: -displayDY).applying(inverse)
        let bounds = page.annotations[index].bounds
        let crop = geometry.cropBounds
        let requested = bounds.offsetBy(dx: delta.x - zero.x, dy: delta.y - zero.y)
        let next = CGRect(
            x: min(max(crop.minX, requested.minX), max(crop.minX, crop.maxX - bounds.width)),
            y: min(max(crop.minY, requested.minY), max(crop.minY, crop.maxY - bounds.height)),
            width: bounds.width, height: bounds.height)
        try transform(index: index, newBounds: next)
    }
    func resize(index: Int, scale: CGFloat) throws {
        guard page.annotations.indices.contains(index) else { return }
        let bounds = page.annotations[index].bounds
        let crop = geometry.cropBounds
        let w = min(crop.width, max(3, bounds.width * scale))
        let h = min(crop.height, max(3, bounds.height * scale))
        let next = CGRect(
            x: min(max(crop.minX, bounds.midX - w / 2), crop.maxX - w),
            y: min(max(crop.minY, bounds.midY - h / 2), crop.maxY - h), width: w, height: h)
        try transform(index: index, newBounds: next)
    }
    func commit(to source: PDFPage, onChange: () async throws -> Void) async throws {
        guard changed else { return }
        // Keep a serialized owner alive so copied PDFAnnotation appearance streams remain valid.
        guard let data = page.dataRepresentation, let copiedDocument = PDFDocument(data: data),
            let copiedPage = copiedDocument.page(at: 0)
        else { throw PDFEditingFailure.saveFailed }
        let originals = source.annotations.filter(Self.isEditable)
        let replacements = copiedPage.annotations.filter(Self.isEditable).compactMap {
            $0.copy() as? PDFAnnotation
        }
        originals.forEach { source.removeAnnotation($0) }
        replacements.forEach {
            // PDFKit lazily reads appearance streams from the annotation's original PDF.
            // Retain that one-page owner for the annotation lifetime, including after dismissal.
            objc_setAssociatedObject(
                $0, &pdfEditingOwnerKey, copiedDocument, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            source.addAnnotation($0)
        }
        defer { withExtendedLifetime(copiedDocument) {} }
        do { try await onChange() } catch {
            replacements.forEach { source.removeAnnotation($0) }
            originals.forEach { source.addAnnotation($0) }
            throw error
        }
        changed = false
    }
}

#if os(iOS)
    /// Snapshot history groups a Pencil gesture (including erasing) into one undo step.
    @MainActor @Observable final class PencilDrawingHistory {
        private var current = PKDrawing()
        private var past: [PKDrawing] = []
        private var future: [PKDrawing] = []
        var canUndo: Bool { !past.isEmpty }
        var canRedo: Bool { !future.isEmpty }
        func record(_ drawing: PKDrawing) {
            guard drawing.dataRepresentation() != current.dataRepresentation() else { return }
            past.append(current)
            current = drawing
            future.removeAll()
        }
        func undo() -> PKDrawing {
            guard let previous = past.popLast() else { return current }
            future.append(current)
            current = previous
            return current
        }
        func redo() -> PKDrawing {
            guard let next = future.popLast() else { return current }
            past.append(current)
            current = next
            return current
        }
        func reset() {
            current = PKDrawing()
            past.removeAll()
            future.removeAll()
        }
    }

    enum PencilInkConversion {
        static func visibleSamples(_ stroke: PKStroke) -> [[PKStrokePoint]] {
            guard !stroke.path.isEmpty else { return [] }
            // Each visible range must become a separate path, never bridge an eraser gap.
            let ranges: [ClosedRange<CGFloat>] =
                stroke.mask == nil
                ? [0...CGFloat(stroke.path.count - 1)] : stroke.maskedPathRanges
            return ranges.map { Array(stroke.path.interpolatedPoints(in: $0, by: .distance(2))) }
        }
    }

    extension PDFAnnotationEditorModel {
        func addPencilDrawing(_ drawing: PKDrawing, canvasSize: CGSize) throws {
            guard let before = page.dataRepresentation else { throw PDFEditingFailure.saveFailed }
            let previousUndo = undoPages
            let previousRedo = redoPages
            let wasChanged = changed
            do {
                for stroke in drawing.strokes {
                    for samples in PencilInkConversion.visibleSamples(stroke) where !samples.isEmpty {
                        let points = samples.map {
                            geometry.pdfPoint(
                                fromCanvas: $0.location.applying(stroke.transform), canvasSize: canvasSize)
                        }
                        let scale = hypot(stroke.transform.a, stroke.transform.b)
                        let width = max(
                            0.25, samples.map { $0.size.width }.reduce(0, +) / CGFloat(samples.count) * scale)
                        try addInk(
                            points: points,
                            width: geometry.pdfWidth(fromCanvas: width, canvasSize: canvasSize),
                            color: Color(stroke.ink.color))
                    }
                }
                // Applying a pending drawing is one transaction in the PDF undo history.
                undoPages = previousUndo + [before]
                redoPages.removeAll()
            } catch {
                if let restored = PDFDocument(data: before) { draft = restored }
                undoPages = previousUndo
                redoPages = previousRedo
                changed = wasChanged
                revision += 1
                throw error
            }
        }
    }
#endif

struct PDFPageEditor: View {
    let source: PDFPage
    let onChange: () async throws -> Void
    let onError: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: PDFAnnotationEditorModel?
    @State private var failure: String?
    @State private var selected: Int?
    @State private var drawing = true
    @State private var color: Color = .blue
    @State private var width = 3.0
    @State private var stroke: [CGPoint] = []
    @State private var text = ""
    @State private var saving = false
    @State private var confirmDiscard = false
    #if os(iOS)
        @State private var pencilCanvas = PKCanvasView()
        @State private var pencilSize = CGSize.zero
        @State private var pencilHasInk = false
        @State private var pencilHistory = PencilDrawingHistory()
        @AppStorage("Paperdesk.allowFingerDrawing") private var allowFingerDrawing = false
    #endif
    init(page: PDFPage, onChange: @escaping () async throws -> Void, onError: @escaping (String) -> Void) {
        source = page
        self.onChange = onChange
        self.onError = onError
        do { _model = State(initialValue: try PDFAnnotationEditorModel(page: page)) } catch {
            _failure = State(initialValue: error.localizedDescription)
        }
    }
    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    GeometryReader { geometry in
                        if geometry.size.width > 740 {
                            HStack(spacing: 0) {
                                pageCanvas(model: model)
                                Divider()
                                inspector(model: model).frame(width: 260)
                            }
                        } else {
                            VStack(spacing: 0) {
                                pageCanvas(model: model)
                                Divider()
                                inspector(model: model).frame(maxHeight: 250)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Page editing unavailable", systemImage: "exclamationmark.triangle",
                        description: Text(failure ?? "This page could not be read."))
                }
            }
            .background { PaperdeskBackdrop() }
            .paperdeskActions()
            .navigationTitle("Edit PDF page")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if model?.changed == true || hasPendingInk {
                            confirmDiscard = true
                        } else {
                            dismiss()
                        }
                    }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }.disabled(saving || model == nil)
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(model?.changed == true || hasPendingInk || saving)
            .confirmationDialog(
                "Discard changes to this page?", isPresented: $confirmDiscard, titleVisibility: .visible
            ) { Button("Discard changes", role: .destructive) { dismiss() } }
            .alert(
                "PDF editing",
                isPresented: Binding(
                    get: { failure != nil && model != nil }, set: { if !$0 { failure = nil } })
            ) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
        .frame(minWidth: 320, minHeight: 480)
    }
    private var hasPendingInk: Bool {
        #if os(iOS)
            pencilHasInk
        #else
            !stroke.isEmpty
        #endif
    }
    private func pageCanvas(model: PDFAnnotationEditorModel) -> some View {
        GeometryReader { available in
            let ratio = model.geometry.aspectRatio
            let width = min(max(1, available.size.width - 24), max(1, available.size.height - 24) * ratio)
            let size = CGSize(width: width, height: width / ratio)
            ZStack {
                Color.gray.opacity(0.12)
                ZStack(alignment: .topLeading) {
                    PagePreview(page: model.page, revision: model.revision)
                    if let selected, model.page.annotations.indices.contains(selected) {
                        let rect = model.geometry.canvasRect(
                            fromPDF: model.page.annotations[selected].bounds, canvasSize: size)
                        Rectangle().stroke(.green, style: StrokeStyle(lineWidth: 2, dash: [5, 3])).frame(
                            width: rect.width, height: rect.height
                        ).position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                    }
                    #if os(iOS)
                        PencilPDFOverlay(
                            canvas: pencilCanvas, drawingEnabled: drawing,
                            allowFingerDrawing: allowFingerDrawing, hasInk: $pencilHasInk,
                            history: pencilHistory
                        )
                        .onAppear { pencilSize = size }
                        .onChange(of: size) { old, new in
                            if old.width > 0 { applyPencil(model: model, size: old) }
                            pencilSize = new
                        }
                    #else
                        Canvas { context, _ in
                            guard let first = stroke.first else { return }
                            var path = Path()
                            path.move(to: first)
                            for point in stroke.dropFirst() { path.addLine(to: point) }
                            context.stroke(
                                path, with: .color(color),
                                style: StrokeStyle(lineWidth: widthForPen, lineCap: .round, lineJoin: .round))
                        }.contentShape(Rectangle()).allowsHitTesting(drawing)
                            .gesture(
                                DragGesture(minimumDistance: 0).onChanged { value in
                                    let point = CGPoint(
                                        x: min(size.width, max(0, value.location.x)),
                                        y: min(size.height, max(0, value.location.y)))
                                    if stroke.isEmpty { stroke.append(value.startLocation) }
                                    stroke.append(point)
                                }.onEnded { _ in
                                    do {
                                        try model.addInk(
                                            points: stroke.map {
                                                model.geometry.pdfPoint(fromCanvas: $0, canvasSize: size)
                                            },
                                            width: model.geometry.pdfWidth(
                                                fromCanvas: widthForPen, canvasSize: size), color: color)
                                    } catch { failure = error.localizedDescription }
                                    stroke.removeAll()
                                })
                    #endif
                }.frame(width: size.width, height: size.height).clipped().background(.white).shadow(radius: 3)
            }
        }
    }
    private var widthForPen: CGFloat { CGFloat(width) }
    private func inspector(model: PDFAnnotationEditorModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Mode", selection: $drawing) {
                    Text("Draw").tag(true)
                    Text("Edit").tag(false)
                }.pickerStyle(.segmented)
                    .onChange(of: drawing) { _, _ in
                        #if os(iOS)
                            applyPencil(model: model, size: pencilSize)
                        #endif
                    }
                if drawing {
                    #if os(macOS)
                        Text("Click and drag with your trackpad or mouse to write directly on this page.")
                            .font(.caption).foregroundStyle(.secondary)
                        ColorPicker("Ink color", selection: $color, supportsOpacity: false)
                        HStack {
                            Text("Width")
                            Slider(value: $width, in: 1...12)
                            Text("\(Int(width))").monospacedDigit()
                        }
                    #else
                        Text(
                            allowFingerDrawing
                                ? "Write with Apple Pencil or your finger. Save embeds strokes into this PDF."
                                : "Write with Apple Pencil. Finger drawing is off for palm rejection. Save embeds strokes into this PDF."
                        ).font(.caption).foregroundStyle(.secondary)
                        Toggle("Draw with finger", isOn: $allowFingerDrawing)
                        Button("Apply ink") { applyPencil(model: model, size: pencilSize) }.disabled(
                            !hasPendingInk)
                    #endif
                }
                HStack {
                    Button {
                        perform {
                            #if os(iOS)
                                if pencilHistory.canUndo {
                                    pencilCanvas.drawing = pencilHistory.undo()
                                    return
                                }
                            #endif
                            try model.undo()
                            selected = nil
                        }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }.disabled(!model.canUndo && !hasPendingInk)
                    Button {
                        perform {
                            #if os(iOS)
                                if pencilHistory.canRedo {
                                    pencilCanvas.drawing = pencilHistory.redo()
                                    return
                                }
                            #endif
                            try model.redo()
                            selected = nil
                        }
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }.disabled(!canRedo(model: model))
                }
                Divider()
                Text("Annotations on this page").font(.headline)
                if model.editableAnnotations.isEmpty {
                    Text("No editable annotations yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.editableAnnotations, id: \.index) { entry in
                    Button {
                        #if os(iOS)
                            applyPencil(model: model, size: pencilSize)
                        #endif
                        drawing = false
                        selected = entry.index
                        text = entry.annotation.contents ?? ""
                    } label: {
                        HStack {
                            Image(systemName: entry.annotation.type == "Ink" ? "pencil.tip" : "highlighter")
                            Text("\(entry.annotation.type ?? "Annotation") \(entry.index + 1)")
                            Spacer()
                            if selected == entry.index { Image(systemName: "checkmark.circle.fill") }
                        }
                        .frame(maxWidth: .infinity).padding(6).background(
                            selected == entry.index ? Color.accentColor.opacity(0.12) : Color.clear
                        ).clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                if let selected, model.page.annotations.indices.contains(selected) {
                    Divider()
                    ColorPicker("Annotation color", selection: $color, supportsOpacity: false)
                    Button("Apply color") { perform { try model.recolor(index: selected, color: color) } }
                    Text("Move").font(.caption)
                    HStack {
                        Button {
                            perform { try model.move(index: selected, displayDX: -8, displayDY: 0) }
                        } label: {
                            Image(systemName: "arrow.left")
                        }.accessibilityLabel("Move left")
                        Button {
                            perform { try model.move(index: selected, displayDX: 0, displayDY: -8) }
                        } label: {
                            Image(systemName: "arrow.up")
                        }.accessibilityLabel("Move up")
                        Button {
                            perform { try model.move(index: selected, displayDX: 0, displayDY: 8) }
                        } label: {
                            Image(systemName: "arrow.down")
                        }.accessibilityLabel("Move down")
                        Button {
                            perform { try model.move(index: selected, displayDX: 8, displayDY: 0) }
                        } label: {
                            Image(systemName: "arrow.right")
                        }.accessibilityLabel("Move right")
                    }
                    HStack {
                        Button("Smaller") { perform { try model.resize(index: selected, scale: 0.9) } }
                        Button("Larger") { perform { try model.resize(index: selected, scale: 1.1) } }
                    }
                    if ["FreeText", "Text"].contains(model.page.annotations[selected].type ?? "") {
                        TextField("Annotation text", text: $text, axis: .vertical)
                        Button("Update text") { perform { try model.setText(index: selected, text: text) } }
                    }
                    Button("Delete annotation", role: .destructive) {
                        perform {
                            try model.remove(index: selected)
                            self.selected = nil
                        }
                    }
                }
                Divider()
                TextField("Text to add", text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
                Button("Add text box") {
                    perform {
                        try model.addText(text)
                        text = ""
                    }
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(
                    "Changes stay in this editor until you Save. Links and form fields are preserved, but are not editable here."
                ).font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }
    private func canRedo(model: PDFAnnotationEditorModel) -> Bool {
        #if os(iOS)
            return pencilHistory.canRedo || (!hasPendingInk && model.canRedo)
        #else
            return model.canRedo
        #endif
    }
    private func perform(_ work: () throws -> Void) {
        do { try work() } catch { failure = error.localizedDescription }
    }
    #if os(iOS)
        @discardableResult private func applyPencil(model: PDFAnnotationEditorModel, size: CGSize) -> Bool {
            guard size.width > 0, size.height > 0 else { return !hasPendingInk }
            let strokes = pencilCanvas.drawing.strokes
            guard !strokes.isEmpty else { return true }
            do {
                try model.addPencilDrawing(pencilCanvas.drawing, canvasSize: size)
                pencilHistory.reset()
                pencilCanvas.drawing = PKDrawing()
                return true
            } catch {
                failure = error.localizedDescription
                return false
            }

        }
    #endif
    private func save() {
        guard let model else { return }
        #if os(iOS)
            guard applyPencil(model: model, size: pencilSize) else { return }
        #endif
        saving = true
        Task {
            do {
                try await model.commit(to: source, onChange: onChange)
                saving = false
                dismiss()
            } catch {
                saving = false
                failure = error.localizedDescription
                onError(error.localizedDescription)
            }
        }
    }
}

private struct PagePreview: View {
    let page: PDFPage
    let revision: Int
    var body: some View {
        let image = page.thumbnail(of: CGSize(width: 1800, height: 1800), for: .cropBox)
        #if os(macOS)
            Image(nsImage: image).resizable().interpolation(.high)
        #else
            Image(uiImage: image).resizable().interpolation(.high)
        #endif
    }
}

#if os(iOS)
    private struct PencilPDFOverlay: UIViewRepresentable {
        let canvas: PKCanvasView
        let drawingEnabled: Bool
        let allowFingerDrawing: Bool
        @Binding var hasInk: Bool
        let history: PencilDrawingHistory
        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
        func makeUIView(context: Context) -> PKCanvasView {
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.drawingPolicy = allowFingerDrawing ? .anyInput : .pencilOnly
            canvas.isScrollEnabled = false
            canvas.tool = PKInkingTool(.pen, color: .systemBlue, width: 3)
            canvas.delegate = context.coordinator
            context.coordinator.picker.addObserver(canvas)
            DispatchQueue.main.async {
                context.coordinator.picker.setVisible(drawingEnabled, forFirstResponder: canvas)
                if drawingEnabled { canvas.becomeFirstResponder() }
            }
            return canvas
        }
        func updateUIView(_ uiView: PKCanvasView, context: Context) {
            context.coordinator.parent = self
            uiView.isUserInteractionEnabled = drawingEnabled
            uiView.drawingPolicy = allowFingerDrawing ? .anyInput : .pencilOnly
            context.coordinator.picker.setVisible(drawingEnabled, forFirstResponder: uiView)
            if drawingEnabled && !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            } else if !drawingEnabled {
                uiView.resignFirstResponder()
            }
        }
        static func dismantleUIView(_ uiView: PKCanvasView, coordinator: Coordinator) {
            coordinator.picker.setVisible(false, forFirstResponder: uiView)
            coordinator.picker.removeObserver(uiView)
        }
        final class Coordinator: NSObject, PKCanvasViewDelegate {
            let picker = PKToolPicker()
            var parent: PencilPDFOverlay
            init(parent: PencilPDFOverlay) { self.parent = parent }
            private var usingTool = false
            func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { usingTool = true }
            func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
                usingTool = false
                parent.history.record(canvasView.drawing)
            }
            func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
                if !usingTool { parent.history.record(canvasView.drawing) }
                parent.hasInk = !canvasView.drawing.strokes.isEmpty
            }
        }
    }
#endif
