import PDFKit
import SwiftUI
#if os(iOS)
import UIKit.UIGestureRecognizerSubclass
#endif

#if os(macOS)
    typealias InkOverlayView = MacInkOverlay
#else
    typealias InkOverlayView = TouchInkOverlay
#endif

/// PDFKit owns each overlay's page transform, including crop, rotation, scrolling and zoom.
@MainActor @Observable final class InlinePDFInk: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    weak var reader: ReaderModel?
    var active = false {
        didSet {
            if active && reader?.editingLocked == true { active = false }
            configure()
        }
    }
    #if os(iOS)
        var allowFingerDrawing = UIDevice.current.userInterfaceIdiom == .phone { didSet { configure() } }
    #endif
    var tool = InkTool.pen { didSet { if tool != .lasso { clearSelection() } } }
    var shape = InkShape.automatic
    var pressureSensitive = true
    var color = Color.blue
    private(set) var selectedAnnotations: [PDFAnnotation] = []
    private weak var selectionPage: PDFPage?
    var selectionBounds: CGRect? {
        selectedAnnotations.isEmpty
            ? nil
            : selectedAnnotations.dropFirst().reduce(selectedAnnotations[0].bounds) { $0.union($1.bounds) }
    }
    var width: CGFloat = 3
    var canUndo: Bool { !undoStrokes.isEmpty }
    var canRedo: Bool { !redoStrokes.isEmpty }
    private(set) var pendingPages: Set<Int> = []
    private(set) var saving = false
    private(set) var saveFailed = false
    private struct Stroke {
        let page: PDFPage
        let removed: [PDFAnnotation]
        let added: [PDFAnnotation]
    }
    private var undoStrokes: [Stroke] = []
    private var redoStrokes: [Stroke] = []
    @ObservationIgnored private var overlays: [ObjectIdentifier: InkOverlayView] = [:]
    #if os(iOS)
        @ObservationIgnored private var scrollPolicies:
            [ObjectIdentifier: (UIPanGestureRecognizer, Int, [NSNumber])] = [:]
    #endif
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(reader: ReaderModel) { self.reader = reader }

    #if os(macOS)
        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? { overlay(for: page) }
    #else
        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? { overlay(for: page) }
    #endif

    private func overlay(for page: PDFPage) -> InkOverlayView {
        let key = ObjectIdentifier(page)
        if let overlay = overlays[key] { return overlay }
        let overlay = InkOverlayView()
        overlay.ink = self
        overlay.page = page
        overlay.enabled = active && (reader?.journalPageReady(page) ?? true)
        Task { [weak self, weak overlay, weak page] in
            guard let self, let page else { return }
            await reader?.loadJournalPage(page)
            overlay?.enabled = active && (reader?.journalPageReady(page) ?? false)
        }
        overlays[key] = overlay
        return overlay
    }

    #if os(macOS)
        func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
            overlays.removeValue(forKey: ObjectIdentifier(page))
        }
    #else
        func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            overlays.removeValue(forKey: ObjectIdentifier(page))
        }
    #endif

    private func configure() {
        guard let view = reader?.view else { return }
        view.isInMarkupMode = active
        overlays.values.forEach { overlay in
            overlay.enabled = active && (overlay.page.map { reader?.journalPageReady($0) ?? false } ?? false)
        }
        #if os(iOS)
            configureScrolling(in: view)
        #endif
        if !active { flush() }
    }

    #if os(iOS)
        private func configureScrolling(in view: UIView) {
            if let scroll = view as? UIScrollView {
                // A single finger or Pencil writes; two fingers pan. Pinch remains native PDFKit zoom.
                let gesture = scroll.panGestureRecognizer
                let key = ObjectIdentifier(gesture)
                if active {
                    if scrollPolicies[key] == nil {
                        scrollPolicies[key] = (
                            gesture, gesture.minimumNumberOfTouches, gesture.allowedTouchTypes
                        )
                    }
                    gesture.minimumNumberOfTouches = allowFingerDrawing ? 2 : 1
                    gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                } else if let original = scrollPolicies.removeValue(forKey: key) {
                    gesture.minimumNumberOfTouches = original.1
                    gesture.allowedTouchTypes = original.2
                }
            }
            for child in view.subviews { configureScrolling(in: child) }
        }
    #endif

    func resetForReload() {
        undoStrokes.removeAll()
        redoStrokes.removeAll()
        overlays.removeAll()
    }
    func addViewStroke(points: [CGPoint], page: PDFPage, pressures: [CGFloat] = [], held: Bool = false) throws
    {
        guard reader?.editingLocked != true, let view = reader?.view else { return }
        let pdfPoints = points.map { view.convert($0, to: page) }
        switch tool {
        case .eraser:
            let hits = page.annotations.filter {
                PDFAnnotationEditorModel.isEditable($0)
                    && InkGeometry.intersects($0, stroke: pdfPoints, radius: max(8, width * 2))
            }
            if !hits.isEmpty { mutate(page: page, removing: hits, adding: []) }
        case .lasso:
            if selectionPage === page, let box = selectionBounds, let first = pdfPoints.first,
                let last = pdfPoints.last, box.contains(first)
            {
                try transformSelection(delta: CGPoint(x: last.x - first.x, y: last.y - first.y))
            } else {
                let polygon = InkGeometry.polygon(pdfPoints)
                selectionPage = page
                selectedAnnotations = page.annotations.filter {
                    PDFAnnotationEditorModel.isEditable($0)
                        && polygon.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY))
                }
                redraw()
            }
        case .shape:
            try addStroke(points: shape.points(from: pdfPoints), page: page)
        case .highlighter:
            let annotation = try PDFInkAnnotation.make(
                points: pdfPoints, width: max(10, width * 4), color: color.opacity(0.3),
                bounds: page.bounds(for: .cropBox))
            mutate(page: page, removing: [], adding: [annotation])
        case .pen:
            if held, let shape = InkGeometry.recognizedShape(pdfPoints) {
                try addStroke(points: shape, page: page); return
            }
            guard pressureSensitive, pressures.count == pdfPoints.count, pressures.count > 1,
                (pressures.max() ?? 1) - (pressures.min() ?? 1) > 0.08
            else {
                try addStroke(points: pdfPoints, page: page); return
            }
            let step = max(4, pdfPoints.count / 24)
            let annotations = try stride(from: 0, to: pdfPoints.count - 1, by: step).map { start in
                let end = min(start + step, pdfPoints.count - 1)
                let pressure = pressures[start...end].reduce(0, +) / CGFloat(end - start + 1)
                return try PDFInkAnnotation.make(
                    points: Array(pdfPoints[start...end]), width: width * (0.4 + pressure), color: color,
                    bounds: page.bounds(for: .cropBox))
            }
            mutate(page: page, removing: [], adding: annotations)
        }
    }
    func addStroke(points: [CGPoint], page: PDFPage, width: CGFloat? = nil) throws {
        let annotation = try PDFInkAnnotation.make(
            points: points, width: width ?? self.width, color: color, bounds: page.bounds(for: .cropBox))
        mutate(page: page, removing: [], adding: [annotation])
    }
    private func mutate(page: PDFPage, removing: [PDFAnnotation], adding: [PDFAnnotation]) {
        removing.forEach { page.removeAnnotation($0) }
        adding.forEach { page.addAnnotation($0) }
        undoStrokes.append(Stroke(page: page, removed: removing, added: adding))
        if undoStrokes.count > 100 { undoStrokes.removeFirst() }
        redoStrokes.removeAll()
        changed(page)
    }
    func undo() {
        guard let stroke = undoStrokes.popLast() else { return }
        stroke.added.forEach { stroke.page.removeAnnotation($0) }
        stroke.removed.forEach { stroke.page.addAnnotation($0) }
        redoStrokes.append(stroke); clearSelection(); changed(stroke.page)
    }
    func redo() {
        guard let stroke = redoStrokes.popLast() else { return }
        stroke.removed.forEach { stroke.page.removeAnnotation($0) }
        stroke.added.forEach { stroke.page.addAnnotation($0) }
        undoStrokes.append(stroke); clearSelection(); changed(stroke.page)
    }
    func clearSelection() { selectedAnnotations.removeAll(); selectionPage = nil; redraw() }
    func selectionBounds(on page: PDFPage) -> CGRect? { selectionPage === page ? selectionBounds : nil }
    func deleteSelection() {
        guard let page = selectionPage, !selectedAnnotations.isEmpty else { return }
        mutate(page: page, removing: selectedAnnotations, adding: []); clearSelection()
    }
    func recolorSelection() {
        guard let page = selectionPage, !selectedAnnotations.isEmpty else { return }
        let replacements = selectedAnnotations.compactMap { $0.copy() as? PDFAnnotation }
        guard replacements.count == selectedAnnotations.count else { return }
        for (copy, original) in zip(replacements, selectedAnnotations) {
            copy.color = InkPlatformColor(color).withAlphaComponent(original.color.cgColor.alpha)
        }
        mutate(page: page, removing: selectedAnnotations, adding: replacements)
        selectedAnnotations = replacements
    }
    func transformSelection(scale: CGFloat = 1, delta: CGPoint = .zero) throws {
        guard scale.isFinite, scale > 0, delta.x.isFinite, delta.y.isFinite,
            let page = selectionPage, let group = selectionBounds else { return }
        let crop = page.bounds(for: .cropBox)
        let factor = min(scale, min(crop.width / max(1, group.width), crop.height / max(1, group.height)))
        let size = CGSize(width: group.width * factor, height: group.height * factor)
        let origin = CGPoint(
            x: min(max(crop.minX, group.midX - size.width / 2 + delta.x), crop.maxX - size.width),
            y: min(max(crop.minY, group.midY - size.height / 2 + delta.y), crop.maxY - size.height))
        let replacements = try selectedAnnotations.map { annotation in
            try InkGeometry.transformedCopy(
                annotation,
                to: CGRect(
                    x: origin.x + (annotation.bounds.minX - group.minX) * factor,
                    y: origin.y + (annotation.bounds.minY - group.minY) * factor,
                    width: annotation.bounds.width * factor, height: annotation.bounds.height * factor))
        }
        mutate(page: page, removing: selectedAnnotations, adding: replacements)
        selectedAnnotations = replacements
    }
    private func redraw() {
        reader?.view.setNeedsDisplayForInk()
        #if os(macOS)
            overlays.values.forEach { $0.needsDisplay = true }
        #else
            overlays.values.forEach { $0.setNeedsDisplay() }
        #endif
    }
    private func changed(_ page: PDFPage) {
        guard let reader, let document = reader.document else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        pendingPages.insert(index)
        reader.status = "Saving ink…"
        reader.view.setNeedsDisplayForInk()
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saving else { return }
        saveTask?.cancel()
        saveTask = Task {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await savePending()
        }
    }

    func flush() {
        guard !saving else { return }
        saveTask?.cancel()
        #if os(iOS)
            let lifetime = DrawingSaveLifetime()
            saveTask = Task {
                defer { lifetime.finish() }
                await savePending()
            }
        #else
            saveTask = Task { await savePending() }
        #endif
    }

    func flushAndWait() async throws {
        flush()
        await saveTask?.value
        if saveFailed || !pendingPages.isEmpty { throw CocoaError(.fileWriteUnknown) }
    }

    /// Serial saves snapshot page changes before awaiting I/O. Later strokes queue a second save.
    func savePending() async {
        // A replaced flush task must not steal the save from the task flushAndWait awaits.
        // Once saving starts, flush() retains that task until its I/O completes.
        guard !Task.isCancelled, !saving, let reader else { return }
        saving = true
        saveFailed = false
        defer { saving = false }
        while !pendingPages.isEmpty {
            if reader.saving {
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            let pages = pendingPages
            pendingPages.subtract(pages)
            do { try await reader.savePDF(pageIndices: Array(pages)) } catch {
                saveFailed = true
                pendingPages.formUnion(pages)
                reader.status = "Ink not saved — retry before closing"
                reader.error =
                    "Your ink is still visible but could not be saved. Keep this document open and use Retry ink save. \(error.localizedDescription)"
                return
            }
        }
    }
}

private extension PDFView {
    func setNeedsDisplayForInk() {
        #if os(macOS)
            needsDisplay = true
            documentView?.needsDisplay = true
        #else
            setNeedsDisplay()
            documentView?.setNeedsDisplay()
        #endif
    }
}

struct InlineInkBar: View {
    @Bindable var ink: InlinePDFInk
    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 14) { controls }
                    .padding(.vertical, 4)
            }
            .accessibilityLabel("Writing tools")
            #if os(iOS)
                Text(
                    ink.allowFingerDrawing
                        ? "Write with one finger or Pencil · two fingers to pan and pinch to zoom"
                        : "Pencil to write · fingers to pan and pinch to zoom"
                )
                .font(.caption).foregroundStyle(.secondary)
            #else
                Text("Drag to write · trackpad gestures or the reader controls to zoom")
                    .font(.caption).foregroundStyle(.secondary)
            #endif
        }
        .padding(10).paperdeskChrome().padding(.horizontal, 10).paperdeskActions()
    }
    @ViewBuilder private var controls: some View {
        Picker("Tool", selection: $ink.tool) {
            ForEach(InkTool.allCases) { tool in Label(tool.rawValue, systemImage: tool.icon).tag(tool) }
        }.pickerStyle(.menu).fixedSize()
        if ink.tool == .shape {
            Picker("Shape", selection: $ink.shape) {
                ForEach(InkShape.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).fixedSize()
        }
        ColorPicker("Ink", selection: $ink.color, supportsOpacity: false).labelsHidden()
            .onChange(of: ink.color) { _, _ in ink.recolorSelection() }
            .accessibilityLabel("Ink color")
        Picker("Pen width", selection: $ink.width) {
            Text("Fine").tag(CGFloat(1.5))
            Text("Medium").tag(CGFloat(3))
            Text("Bold").tag(CGFloat(6))
        }.pickerStyle(.menu).fixedSize()
        Menu {
            Toggle("Pressure-sensitive pen", isOn: $ink.pressureSensitive)
            Button("Blue") { ink.color = .blue }
            Button("Black") { ink.color = .black }
            Button("Red") { ink.color = .red }
            Button("Yellow") { ink.color = .yellow }
        } label: {
            Label("Pen options", systemImage: "slider.horizontal.3")
        }.labelStyle(.iconOnly)
        if !ink.selectedAnnotations.isEmpty {
            Menu("Selection (\(ink.selectedAnnotations.count))") {
                Button("Smaller") { try? ink.transformSelection(scale: 0.9) }
                Button("Larger") { try? ink.transformSelection(scale: 1.1) }
                Button("Recolor") { ink.recolorSelection() }
                Button("Delete", role: .destructive) { ink.deleteSelection() }
                Button("Clear selection") { ink.clearSelection() }
            }
        }
        HStack {
            Button("Undo ink", systemImage: "arrow.uturn.backward") { ink.undo() }
                .labelStyle(.iconOnly).disabled(!ink.canUndo)
            Button("Redo ink", systemImage: "arrow.uturn.forward") { ink.redo() }
                .labelStyle(.iconOnly).disabled(!ink.canRedo)
        }
        if ink.saveFailed && !ink.saving {
            Button("Retry ink save") { ink.flush() }
        }
        #if os(iOS)
            Toggle("Finger drawing", isOn: $ink.allowFingerDrawing).fixedSize()
                .accessibilityHint("When enabled, use two fingers to scroll and pinch to zoom")
        #endif
        Button("Done", systemImage: "checkmark") { ink.active = false }
    }
}

#if os(macOS)
    final class MacInkOverlay: NSView {
        weak var ink: InlinePDFInk?
        weak var page: PDFPage?
        var enabled = false
        private var points: [CGPoint] = []
        private var pressures: [CGFloat] = []
        private var lastMove: TimeInterval = 0
        override func hitTest(_ point: NSPoint) -> NSView? { enabled ? super.hitTest(point) : nil }
        override func mouseDown(with event: NSEvent) {
            points = [convert(event.locationInWindow, from: nil)]
            pressures = [event.pressure > 0 ? CGFloat(event.pressure) : 1]
            lastMove = event.timestamp
        }
        override func mouseDragged(with event: NSEvent) {
            points.append(convert(event.locationInWindow, from: nil))
            pressures.append(event.pressure > 0 ? CGFloat(event.pressure) : 1)
            lastMove = event.timestamp
            needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
            guard let ink, let page, let view = ink.reader?.view else { return }
            points.append(convert(event.locationInWindow, from: nil))
            pressures.append(pressures.last ?? 1)
            do {
                try ink.addViewStroke(
                    points: points.map { view.convert($0, from: self) }, page: page, pressures: pressures,
                    held: event.timestamp - lastMove >= 0.35)
            } catch { ink.reader?.error = error.localizedDescription }
            points.removeAll(); pressures.removeAll(); needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            guard let ink else { return }
            if let page, let view = ink.reader?.view, let rect = ink.selectionBounds(on: page) {
                let selected = NSBezierPath(rect: convert(view.convert(rect, from: page), from: view))
                selected.lineWidth = 1.5; selected.setLineDash([5, 3], count: 2, phase: 0)
                NSColor.systemTeal.setStroke(); selected.stroke()
            }
            guard let first = points.first else { return }
            let path = NSBezierPath(); path.move(to: first)
            points.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth = ink.tool == .highlighter ? max(10, ink.width * 4) : ink.width
            path.lineCapStyle = .round
            NSColor(ink.color).withAlphaComponent(ink.tool == .highlighter ? 0.3 : 1).setStroke();
            path.stroke()
        }
    }
#else
    /// Coalesced Pencil samples retain pressure while native two-finger pan/pinch recognizers stay enabled.
    final class InkTouchGesture: UIGestureRecognizer {
        private(set) var points: [CGPoint] = []
        private(set) var pressures: [CGFloat] = []
        private var touch: UITouch?
        private var lastMove: TimeInterval = 0
        private(set) var held = false
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard touch == nil, touches.count == 1, let first = touches.first else {
                state = state == .possible ? .failed : .cancelled; return
            }
            touch = first; points = [first.location(in: view)]; pressures = [pressure(first)]
            lastMove = first.timestamp; state = .began
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch, touches.contains(touch) else { return }
            for sample in event.coalescedTouches(for: touch) ?? [touch] {
                let point = sample.location(in: view)
                if let last = points.last, InkGeometry.distance(point, last) > 0.5 {
                    lastMove = sample.timestamp
                }
                points.append(point); pressures.append(pressure(sample))
            }
            state = .changed
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch, touches.contains(touch) else { return }
            points.append(touch.location(in: view)); pressures.append(pressure(touch))
            held = touch.timestamp - lastMove >= 0.35; state = .ended
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
        override func reset() {
            super.reset(); touch = nil; points.removeAll(); pressures.removeAll(); held = false
        }
        private func pressure(_ touch: UITouch) -> CGFloat {
            touch.type == .pencil && touch.maximumPossibleForce > 0
                ? min(1, max(0.05, touch.force / touch.maximumPossibleForce)) : 1
        }
    }
    final class TouchInkOverlay: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        weak var ink: InlinePDFInk?
        weak var page: PDFPage?
        var enabled = false {
            didSet {
                isUserInteractionEnabled = enabled
                let types: [UITouch.TouchType] =
                    ink?.allowFingerDrawing == true ? [.direct, .pencil] : [.pencil]
                pen.allowedTouchTypes = types.map { NSNumber(value: $0.rawValue) }
            }
        }
        private lazy var pen = InkTouchGesture(target: self, action: #selector(drawStroke(_:)))
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear; isOpaque = false; isMultipleTouchEnabled = true
            pen.delegate = self; addGestureRecognizer(pen)
            let pencil = UIPencilInteraction(); pencil.delegate = self; addInteraction(pencil)
        }
        required init?(coder: NSCoder) { nil }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer is UIPinchGestureRecognizer
                || otherGestureRecognizer is UIPanGestureRecognizer
        }
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            performPencilAction(UIPencilInteraction.preferredTapAction)
        }
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            performPencilAction(UIPencilInteraction.preferredTapAction)
        }
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            if squeeze.phase == .ended { performPencilAction(UIPencilInteraction.preferredSqueezeAction) }
        }
        private func performPencilAction(_ action: UIPencilPreferredAction) {
            switch action {
            case .switchEraser: ink?.tool = ink?.tool == .eraser ? .pen : .eraser
            case .switchPrevious: ink?.tool = ink?.tool == .highlighter ? .pen : .highlighter
            default: break
            }
        }
        @objc private func drawStroke(_ gesture: InkTouchGesture) {
            guard let ink, let page, let view = ink.reader?.view else { return }
            if gesture.state == .ended {
                do {
                    try ink.addViewStroke(
                        points: gesture.points.map { convert($0, to: view) }, page: page,
                        pressures: gesture.pressures, held: gesture.held)
                } catch { ink.reader?.error = error.localizedDescription }
            }
            setNeedsDisplay()
        }
        override func draw(_ rect: CGRect) {
            guard let ink else { return }
            if let page, let view = ink.reader?.view, let bounds = ink.selectionBounds(on: page) {
                let selected = UIBezierPath(rect: convert(view.convert(bounds, from: page), from: view))
                selected.lineWidth = 1.5; selected.setLineDash([5, 3], count: 2, phase: 0)
                UIColor.systemTeal.setStroke(); selected.stroke()
            }
            guard [.began, .changed].contains(pen.state), let first = pen.points.first else { return }
            let path = UIBezierPath(); path.move(to: first);
            pen.points.dropFirst().forEach { path.addLine(to: $0) }
            path.lineWidth = ink.tool == .highlighter ? max(10, ink.width * 4) : ink.width;
            path.lineCapStyle = .round
            UIColor(ink.color).withAlphaComponent(ink.tool == .highlighter ? 0.3 : 1).setStroke();
            path.stroke()
        }
    }
#endif
