import MapKit
import SwiftUI

/// A picture of a guess for sharing: the map under the shape, with the target and result on top.
struct ShareCard: View {
    let map: NSImage
    let target: Double
    let total: Double
    let region: Region

    static let size = CGSize(width: 600, height: 400)

    var body: some View {
        let ratio = total / target
        let verdict = Verdict(ratio: ratio)
        ZStack(alignment: .bottomLeading) {
            Image(nsImage: map)
                .resizable()
                .frame(width: Self.size.width, height: Self.size.height)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(region.flag ?? "") \(region == .world ? "Anywhere on Earth" : region.name)")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.people(total))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("of \(Format.people(target)) people")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                }
                HStack(spacing: 10) {
                    Label(verdict.title, systemImage: verdict.symbol)
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(verdict.color.opacity(0.35), in: Capsule())
                    Text(Format.percentOff(ratio))
                        .font(.headline.monospacedDigit())
                    Spacer()
                    Text("Populus")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .foregroundStyle(.white)
            .padding(20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }

    /// One line to go with the picture.
    static func text(target: Double, total: Double, region: Region) -> String {
        let ratio = total / target
        let place = region == .world ? "anywhere on Earth" : "in \(region.name)"
        return "Populus: I enclosed \(Format.compact(total)) of \(Format.compact(target)) people \(place) "
            + "(\(Format.percentOff(ratio)), \(Verdict(ratio: ratio).title)). \(Links.repo.absoluteString)"
    }

    /// Renders the card as a PNG-ready image, or nil if the map can't be drawn.
    @MainActor
    static func image(shape: [GeoPoint], target: Double, total: Double, region: Region, style: MapStyle) async -> NSImage? {
        guard let map = await snapshot(shape, style: style) else { return nil }
        let renderer = ImageRenderer(content: ShareCard(map: map, target: target, total: total, region: region))
        renderer.scale = 2
        return renderer.nsImage
    }

    /// The map around `shape` with the shape drawn on it.
    @MainActor
    private static func snapshot(_ shape: [GeoPoint], style: MapStyle) async -> NSImage? {
        // Same projection as MapView, so shapes past ±180° stay in one piece.
        let w = MKMapSize.world.width
        let pts = shape.map { g in
            MKMapPoint(x: (g.lon + 180) / 360 * w,
                       y: MKMapPoint(CLLocationCoordinate2D(latitude: min(85.05, max(-85.05, g.lat)), longitude: 0)).y)
        }
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return nil }
        // Pad the shape and widen whichever side is short to match the card.
        let aspect = size.width / size.height
        var rw = (maxX - minX) * 1.5, rh = (maxY - minY) * 1.5
        if rw / rh < aspect { rw = rh * aspect } else { rh = rw / aspect }
        let rect = MKMapRect(x: (minX + maxX - rw) / 2, y: (minY + maxY - rh) / 2, width: rw, height: rh)

        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = size
        switch style {
        case .day:
            let config = MKHybridMapConfiguration(elevationStyle: .flat)
            config.pointOfInterestFilter = .excludingAll
            options.preferredConfiguration = config
            options.appearance = NSAppearance(named: .aqua)
        case .night:
            let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            config.pointOfInterestFilter = .excludingAll
            options.preferredConfiguration = config
            options.appearance = NSAppearance(named: .darkAqua)
        }
        guard let shot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        // MapKit can snap to a slightly different zoom, so measure where two points landed (y points up).
        let a = MKMapPoint(x: rect.midX, y: rect.midY)
        let b = MKMapPoint(x: rect.midX + rect.width / 4, y: rect.midY + rect.height / 4)
        let pa = shot.point(for: a.coordinate), pb = shot.point(for: b.coordinate)
        let sx = (pb.x - pa.x) / (b.x - a.x), sy = (pb.y - pa.y) / (b.y - a.y)

        let image = shot.image
        image.lockFocus()
        let path = NSBezierPath()
        for (i, p) in pts.enumerated() {
            let q = CGPoint(x: pa.x + (p.x - a.x) * sx, y: pa.y + (p.y - a.y) * sy)
            if i == 0 { path.move(to: q) } else { path.line(to: q) }
        }
        path.close()
        Palette.shape.withAlphaComponent(0.16).setFill()
        path.fill()
        path.lineWidth = 3
        path.lineJoinStyle = .round
        Palette.shape.setStroke()
        path.stroke()
        image.unlockFocus()
        return image
    }
}
