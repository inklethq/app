import SwiftUI

/// Dot.'s mark, from https://dot.mindreset.tech/logo/single_logo.svg — a single
/// filled path in a 150×150 box. Drawn as a Shape rather than bundled as an
/// SVG so it takes the foreground style and scales like the SF Symbols beside
/// it. It is Mindreset's logo and stands for their product, the Quote/0.
struct DotLogo: Shape {
    /// The vertices, in the SVG's own coordinates, in path order.
    private static let points: [CGPoint] = [
        (125.917, 115.172), (109.9568, 121.553), (99.328, 135.066), (82.3104, 132.611),
        (66.3506, 139), (52.8374, 128.363), (35.828, 125.917), (29.4392, 109.9568),
        (15.93414, 99.328), (18.38058, 82.3104), (12, 66.3506), (22.6288, 52.8374),
        (25.0835, 35.828), (41.0432, 29.4392), (51.672, 15.93414), (68.6896, 18.38058),
        (84.6494, 12), (98.1544, 22.6288), (115.172, 25.0835), (121.553, 41.0432),
        (135.066, 51.672), (132.611, 68.6896), (139, 84.6494), (128.363, 98.1544),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    /// The path's own bounds: 12…139 both ways, so the mark fills the rect
    /// rather than sitting inside the SVG's 12-unit margin.
    private static let box = CGRect(x: 12, y: 12, width: 127, height: 127)

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.box.width, rect.height / Self.box.height)
        let size = CGSize(width: Self.box.width * scale, height: Self.box.height * scale)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + (point.x - Self.box.minX) * scale,
                    y: origin.y + (point.y - Self.box.minY) * scale)
        }
        var path = Path()
        path.move(to: place(Self.points[0]))
        for point in Self.points.dropFirst() {
            path.addLine(to: place(point))
        }
        path.closeSubpath()
        return path
    }
}

extension DotLogo {
    /// The mark as a template image, for the places that take an image rather
    /// than a view — menu rows and pickers, which AppKit draws itself. Drawn
    /// by a handler, so it is rasterised again at whatever scale it is shown.
    @MainActor
    static func nsImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(DotLogo().path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
