import PDFKit
import SwiftUI
#if os(macOS)
    typealias InkPlatformColor = NSColor
    typealias InkPlatformPath = NSBezierPath
#else
    typealias InkPlatformColor = UIColor
    typealias InkPlatformPath = UIBezierPath
#endif

enum InkTool: String, CaseIterable, Identifiable {
    case pen = "Pen", highlighter = "Highlighter", eraser = "Stroke eraser", lasso = "Lasso", shape = "Shape"
    var id: Self { self }
    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .shape: "triangle.square"
        }
    }
}

enum InkGeometry {
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    static func distance(_ p: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0 else { return distance(p, a) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / denominator))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
    static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }
    static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        if let first = points.first {
            path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath()
        }
        return path
    }
    static func points(in annotation: PDFAnnotation) -> [[CGPoint]] {
        (annotation.paths ?? []).map { path in
            #if os(macOS)
                let cgPath = path.cgPath
            #else
                let cgPath = path.cgPath
            #endif
            var points: [CGPoint] = []
            cgPath.applyWithBlock { element in
                let value = element.pointee
                switch value.type {
                case .moveToPoint, .addLineToPoint: points.append(value.points[0])
                case .addQuadCurveToPoint: points.append(value.points[1])
                case .addCurveToPoint: points.append(value.points[2])
                default: break
                }
            }
            return points.map { CGPoint(x: $0.x + annotation.bounds.minX, y: $0.y + annotation.bounds.minY) }
        }
    }
    static func intersects(_ annotation: PDFAnnotation, stroke: [CGPoint], radius: CGFloat) -> Bool {
        let box = annotation.bounds.insetBy(dx: -radius, dy: -radius)
        guard bounds(stroke).intersects(box) || stroke.contains(where: box.contains) else { return false }
        let paths = points(in: annotation)
        guard !paths.isEmpty else { return true }
        let tolerance = radius + (annotation.border?.lineWidth ?? 1) / 2
        return paths.contains { path in
            guard let first = path.first, let start = stroke.first else { return false }
            let inkSegments = path.count == 1 ? [(first, first)] : Array(zip(path, path.dropFirst()))
            let eraserSegments = stroke.count == 1 ? [(start, start)] : Array(zip(stroke, stroke.dropFirst()))
            return inkSegments.contains { a, b in
                eraserSegments.contains { c, d in
                    segmentDistance(a, b, c, d) <= tolerance
                }
            }
        }
    }
    private static func segmentDistance(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat {
        func cross(_ u: CGPoint, _ v: CGPoint, _ w: CGPoint) -> CGFloat {
            (v.x - u.x) * (w.y - u.y) - (v.y - u.y) * (w.x - u.x)
        }
        let abC = cross(a, b, c), abD = cross(a, b, d)
        let cdA = cross(c, d, a), cdB = cross(c, d, b)
        if ((abC < 0 && abD > 0) || (abC > 0 && abD < 0)),
            ((cdA < 0 && cdB > 0) || (cdA > 0 && cdB < 0)) { return 0 }
        return min(distance(a, from: c, to: d), distance(b, from: c, to: d),
                   distance(c, from: a, to: b), distance(d, from: a, to: b))
    }
    /// Deliberate hold-to-shape keeps ordinary handwriting untouched.
    static func recognizedShape(_ points: [CGPoint]) -> [CGPoint]? {
        guard let first = points.first, let last = points.last, points.count > 3 else { return nil }
        let box = bounds(points)
        let diagonal = hypot(box.width, box.height)
        guard diagonal > 8 else { return nil }
        let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + distance($1.0, $1.1) }
        if distance(first, last) / max(1, length) > 0.9 { return [first, last] }
        guard distance(first, last) < max(12, diagonal * 0.22), min(box.width, box.height) > 4 else {
            return nil
        }
        let edgeTolerance = min(box.width, box.height) * 0.08
        let nearEdge = points.filter {
            min($0.x - box.minX, box.maxX - $0.x, $0.y - box.minY, box.maxY - $0.y) < edgeTolerance
        }.count
        if Double(nearEdge) / Double(points.count) > 0.85 {
            return [
                CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
                CGPoint(x: box.minX, y: box.minY),
            ]
        }
        let error =
            points.reduce(CGFloat.zero) { result, point in
                result
                    + abs(
                        hypot((point.x - box.midX) / (box.width / 2), (point.y - box.midY) / (box.height / 2))
                            - 1)
            } / CGFloat(points.count)
        guard error < 0.25 else { return nil }
        return (0...64).map { i in
            let angle = CGFloat(i) / 64 * 2 * .pi
            return CGPoint(
                x: box.midX + cos(angle) * box.width / 2, y: box.midY + sin(angle) * box.height / 2)
        }
    }
    static func transformedCopy(_ original: PDFAnnotation, to bounds: CGRect) throws -> PDFAnnotation {
        guard bounds.width > 0, bounds.height > 0, bounds.minX.isFinite, bounds.minY.isFinite,
            bounds.width.isFinite, bounds.height.isFinite,
            let annotation = original.copy() as? PDFAnnotation else { throw PDFEditingFailure.saveFailed }
        let old = original.bounds
        guard old.width > 0, old.height > 0 else { return annotation }
        let sx = bounds.width / old.width, sy = bounds.height / old.height
        for path in (annotation.type ?? "").lowercased() == "ink" ? annotation.paths ?? [] : [] {
            guard let resized = path.copy() as? InkPlatformPath else { throw PDFEditingFailure.saveFailed }
            #if os(macOS)
                resized.transform(using: AffineTransform(m11: sx, m12: 0, m21: 0, m22: sy, tX: 0, tY: 0))
            #else
                resized.apply(CGAffineTransform(scaleX: sx, y: sy))
            #endif
            annotation.remove(path); annotation.add(resized)
        }
        if let quads = annotation.quadrilateralPoints {
            annotation.quadrilateralPoints = quads.map {
                #if os(macOS)
                    NSValue(point: CGPoint(x: $0.pointValue.x * sx, y: $0.pointValue.y * sy))
                #else
                    NSValue(cgPoint: CGPoint(x: $0.cgPointValue.x * sx, y: $0.cgPointValue.y * sy))
                #endif
            }
        }
        annotation.startPoint = CGPoint(x: annotation.startPoint.x * sx, y: annotation.startPoint.y * sy)
        annotation.endPoint = CGPoint(x: annotation.endPoint.x * sx, y: annotation.endPoint.y * sy)
        annotation.bounds = bounds
        return annotation
    }
}

enum InkShape: String, CaseIterable, Identifiable {
    case automatic = "Recognize", line = "Line", arrow = "Arrow", rectangle = "Rectangle", ellipse = "Ellipse"
    var id: Self { self }
    func points(from input: [CGPoint]) -> [CGPoint] {
        guard let first = input.first, let last = input.last else { return input }
        let box = InkGeometry.bounds(input)
        switch self {
        case .automatic: return InkGeometry.recognizedShape(input) ?? input
        case .line: return [first, last]
        case .arrow:
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = min(36, max(8, InkGeometry.distance(first, last) * 0.2))
            return [
                first, last,
                CGPoint(x: last.x - cos(angle - .pi / 6) * length, y: last.y - sin(angle - .pi / 6) * length),
                last,
                CGPoint(x: last.x - cos(angle + .pi / 6) * length, y: last.y - sin(angle + .pi / 6) * length),
            ]
        case .rectangle:
            return [
                CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
                CGPoint(x: box.minX, y: box.minY),
            ]
        case .ellipse:
            return (0...64).map { i in
                let angle = CGFloat(i) / 64 * 2 * .pi
                return CGPoint(
                    x: box.midX + cos(angle) * box.width / 2, y: box.midY + sin(angle) * box.height / 2)
            }
        }
    }

}
