import MapKit
import SwiftUI

/// MapKit's map without the scroll edge blur macOS puts under the toolbar. In full screen
/// that blur grows to cover the whole map.
final class PlainMapView: MKMapView {
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        hideScrollPocket()
    }

    override func layout() {
        super.layout()
        hideScrollPocket()
    }

    private func hideScrollPocket() {
        for sub in subviews where String(describing: type(of: sub)).contains("ScrollPocket") {
            sub.isHidden = true
        }
    }
}

final class MapContainerView: NSView {
    let mapView = PlainMapView()
    let drawingView = DrawingOverlayView()
    var onFirstLayout: (() -> Void)?

    override func layout() {
        super.layout()
        if bounds.width > 0, let first = onFirstLayout {
            onFirstLayout = nil
            first()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for v in [mapView, drawingView] as [NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A frozen picture of part of the map and the area it covers.
struct Backdrop {
    let image: CGImage
    let rect: MKMapRect
}

/// Dims everything outside the round's region, drawn over a backdrop when there is one.
final class DimRenderer: MKMultiPolygonRenderer {
    var backdrop: Backdrop? {
        didSet { setNeedsDisplay() }
    }

    override func fillPath(_ path: CGPath, in context: CGContext) {
        if let backdrop {
            let r = rect(for: backdrop.rect)
            context.saveGState()
            context.addPath(path)
            context.clip(using: .evenOdd)
            // The renderer's y axis points down, so flip to draw the image upright.
            context.translateBy(x: r.minX, y: r.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(backdrop.image, in: CGRect(origin: .zero, size: r.size))
            context.restoreGState()
        }
        super.fillPath(path, in: context)
    }
}

/// Polygon renderer with a soft glow and an animatable outline width.
final class ShapeRenderer: MKPolygonRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        context.saveGState()
        context.setShadow(offset: .zero, blur: 14, color: Palette.shape.withAlphaComponent(0.9).cgColor)
        super.draw(mapRect, zoomScale: zoomScale, in: context)
        context.restoreGState()
    }
}

struct MapView: NSViewRepresentable {
    var style: MapStyle
    var densityVisible: Bool
    var shape: [GeoPoint]?
    var interactive: Bool
    var tool: Tool
    var focus: FocusRequest?
    var pulseToken: Int
    /// Region the camera is held to; nil for the whole world.
    var region: Region?
    /// The next round's region, loaded ahead of time.
    var upcoming: Region?
    var onCommit: ([GeoPoint]) -> Void
    var onSpace: (Bool) -> Void
    var onEscape: () -> Void
    var onFirstRender: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MapContainerView {
        let view = MapContainerView()
        context.coordinator.attach(view, parent: self)
        return view
    }

    func updateNSView(_ view: MapContainerView, context: Context) {
        context.coordinator.sync(self)
    }

    static func dismantleNSView(_ view: MapContainerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private var parent: MapView!
        private weak var container: MapContainerView?
        private var map: MKMapView { container!.mapView }
        private var drawing: DrawingOverlayView { container!.drawingView }

        private var style: MapStyle?
        private var shape: [GeoPoint]?
        private var densityVisible = false
        private var lastFocus: UUID?
        private var pulseToken = 0

        private var region: Region?
        private var layoutReady = false
        private var pendingFocus: FocusRequest.Target?
        private var pendingLock = false
        private var flyingToRegion: Region?
        private var lockDistance: [Region: Double] = [:]
        private var regionDim: MKMultiPolygon?
        private var regionBorder: MKMultiPolyline?
        private var backdrop: Backdrop?
        private var backdropToken = 0

        private var upcoming: Region?
        /// Built for `upcoming` while the current round is played, and used when it starts.
        private var prepared: (region: Region, dim: MKMultiPolygon, border: MKMultiPolyline)?
        private var preparedBackdrop: (region: Region, style: MapStyle, backdrop: Backdrop)?
        private var prefetchToken = 0

        private let nightOverlay = NightLightsOverlay()
        private lazy var densityOverlay: DensityTileOverlay? = PopulationGrid.shared.map(DensityTileOverlay.init)
        private var shapeOverlay: MKPolygon?
        private var keyMonitor: Any?
        private var fadeTimer: Timer?
        private var pulseTimer: Timer?
        private var regionSettled = false
        private var reportedRender = false

        func attach(_ view: MapContainerView, parent: MapView) {
            container = view
            self.parent = parent
            let map = view.mapView
            map.delegate = self
            map.isPitchEnabled = false
            map.isRotateEnabled = false
            map.showsCompass = false
            map.showsZoomControls = true
            map.showsScale = false

            drawing.onCommit = { [weak self] pts in
                guard let self else { return }
                self.parent.onCommit(self.geo(pts))
            }
            drawing.shapePath = { [weak self] in self?.screenPath() }
            drawing.onMoveBegan = { [weak self] in self?.shapeRenderer?.alpha = 0 }
            drawing.onMoveEnded = { [weak self] delta in self?.finishMove(delta) }

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                self?.handleKey(event) ?? event
            }

            sync(parent)
            view.onFirstLayout = { [weak self] in
                guard let self else { return }
                self.layoutReady = true
                self.updateBackdrop()
                self.prefetch()
                if let target = self.pendingFocus {
                    self.pendingFocus = nil
                    self.regionRestored = true
                    self.perform(target)
                } else {
                    self.restoreRegion()
                }
            }
        }

        func detach() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }

        func sync(_ p: MapView) {
            parent = p
            if p.style != style {
                apply(style: p.style, animated: style != nil)
                style = p.style
                updateBackdrop()
                prefetch()
            }
            if p.densityVisible != densityVisible {
                densityVisible = p.densityVisible
                setDensity(visible: p.densityVisible)
            }
            if p.shape != shape {
                shape = p.shape
                setShape(p.shape)
            }
            if p.region != region {
                region = p.region
                setRegion(p.region)
            }
            if p.upcoming != upcoming {
                upcoming = p.upcoming
                prefetch()
            }
            if let f = p.focus, f.id != lastFocus {
                lastFocus = f.id
                if layoutReady { perform(f.target) } else { pendingFocus = f.target }
            }
            if p.pulseToken != pulseToken {
                pulseToken = p.pulseToken
                pulse()
            }
            drawing.tool = p.tool
            drawing.isInteractive = p.interactive
        }

        // MARK: Focus and region lock

        private static var worldRect: MKMapRect {
            // MapKit zooms out to about half the world's width at most, so show that much, centred on Europe.
            let c = MKMapPoint(CLLocationCoordinate2D(latitude: 45, longitude: 15))
            let w = MKMapSize.world.width / 2
            return MKMapRect(x: c.x - w / 2, y: c.y - w / 4, width: w, height: w / 2)
        }

        /// The top clears the toolbar and the target card.
        private static let regionPadding = NSEdgeInsets(top: 180, left: 40, bottom: 120, right: 40)

        private func perform(_ target: FocusRequest.Target) {
            switch target {
            case .world:
                clearLocks()
                map.setVisibleMapRect(Self.worldRect, animated: true)
            case .region(let r):
                guard let b = r.bounds else { return }
                clearLocks()
                flyingToRegion = r
                map.setVisibleMapRect(Self.rect(b), edgePadding: Self.regionPadding, animated: true)
            case .shape(let s):
                fly(to: s)
            }
            if region != nil {
                pendingLock = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.applyLockIfPending() }
            }
        }

        private func setRegion(_ r: Region?) {
            clearLocks()
            map.removeOverlays([regionDim, regionBorder].compactMap { $0 })
            regionDim = nil
            regionBorder = nil
            updateBackdrop()
            guard let r, let outline = r.outline else { return }
            let ready = prepared?.region == r ? prepared : nil
            let dim = ready?.dim ?? Self.outside(outline), border = ready?.border ?? Self.border(outline)
            regionDim = dim
            regionBorder = border
            insert(dim)
            insert(border)
        }

        /// Our overlays sit under MapKit's labels, so place names never get dimmed or cut by a
        /// border, stacked in this order from the bottom.
        private func rank(_ overlay: any MKOverlay) -> Int {
            if overlay === nightOverlay { return 0 }
            if overlay === densityOverlay { return 1 }
            if overlay === regionDim { return 2 }
            if overlay === regionBorder { return 3 }
            return 4
        }

        private func insert(_ overlay: any MKOverlay) {
            let r = rank(overlay)
            if let next = map.overlays(in: .aboveRoads).first(where: { rank($0) > r }) {
                map.insertOverlay(overlay, below: next)
            } else {
                map.addOverlay(overlay, level: .aboveRoads)
            }
        }

        // MARK: Country backdrop

        /// In country rounds everything outside the country is frozen as one picture taken at the
        /// fly-in zoom, so zooming in only sharpens the country itself.
        private func updateBackdrop() {
            backdropToken += 1
            backdrop = nil
            if let dim = regionDim { (map.renderer(for: dim) as? DimRenderer)?.backdrop = nil }
            guard layoutReady, let region, let style else { return }
            if let p = preparedBackdrop, p.region == region, p.style == style {
                backdrop = p.backdrop
                return
            }
            let token = backdropToken
            Task { [weak self] in
                guard let self, let result = await self.makeBackdrop(for: region, style: style),
                      token == self.backdropToken else { return }
                self.backdrop = result
                if let dim = self.regionDim { (self.map.renderer(for: dim) as? DimRenderer)?.backdrop = result }
            }
        }

        /// The picture behind a country round; nil for other rounds.
        private func makeBackdrop(for region: Region, style: MapStyle) async -> Backdrop? {
            guard case .country = region, let b = region.bounds else { return nil }
            let fit = map.mapRectThatFits(Self.rect(b), edgePadding: Self.regionPadding)
            // Twice the fly-in view each way, to cover panning to the edges and zooming out a little.
            var rect = fit.insetBy(dx: -fit.width / 2, dy: -fit.height / 2)
            rect.origin.y = max(0, rect.minY)
            rect.size.height = min(MKMapRect.world.maxY, fit.maxY + fit.height / 2) - rect.minY
            // Screen points per map point: a little under the fly-in view's, capped to keep memory sane.
            let k = min(0.8 * map.bounds.width / fit.width, 2400 / max(rect.width, rect.height))
            switch style {
            case .day:
                return await Self.snapshot(rect, size: CGSize(width: rect.width * k, height: rect.height * k))
            case .night:
                let z = Int(log2(k * MKMapSize.world.width / 256).rounded(.down))
                return await Self.stitch(nightOverlay, rect: rect, z: min(8, max(0, z)))
            }
        }

        // MARK: Prefetch

        /// Loads the next round's borders, map tiles and backdrop while this round is played,
        /// so the next round opens on a finished map.
        private func prefetch() {
            prefetchToken += 1
            let token = prefetchToken
            guard let next = upcoming else { return }
            Task { [weak self] in
                if self?.prepared?.region != next {
                    // The first use of the outline files decodes them, and big countries have many rings.
                    let overlays = await Task.detached(priority: .utility) { () -> (MKMultiPolygon, MKMultiPolyline)? in
                        if case .city(let id) = next { _ = Metros.shared?.level(id) }
                        return next.outline.map { (Self.outside($0), Self.border($0)) }
                    }.value
                    guard let self, token == self.prefetchToken else { return }
                    self.prepared = overlays.map { (next, $0.0, $0.1) }
                }
                guard let self, self.layoutReady, let style = self.style else { return }
                await self.warmTiles(for: next, style: style)
                guard token == self.prefetchToken,
                      let backdrop = await self.makeBackdrop(for: next, style: style),
                      token == self.prefetchToken else { return }
                self.preparedBackdrop = (next, style, backdrop)
            }
        }

        /// Draws the round's opening view off screen. MapKit keeps the tiles in a cache shared
        /// with the map view, and the night lights land in the overlay's URL cache.
        private func warmTiles(for next: Region, style: MapStyle) async {
            let rect = next.bounds.map { map.mapRectThatFits(Self.rect($0), edgePadding: Self.regionPadding) } ?? Self.worldRect
            let options = MKMapSnapshotter.Options()
            options.mapRect = rect
            options.size = map.bounds.size
            options.preferredConfiguration = map.preferredConfiguration
            options.appearance = map.appearance
            _ = try? await MKMapSnapshotter(options: options).start()
            if style == .night {
                let z = Int(log2(MKMapSize.world.width / rect.width * map.bounds.width / 256).rounded(.up))
                _ = await Self.stitch(nightOverlay, rect: rect, z: min(8, max(0, z)))
            }
        }

        private static func snapshot(_ rect: MKMapRect, size: CGSize) async -> Backdrop? {
            let options = MKMapSnapshotter.Options()
            options.mapRect = rect
            options.size = size
            options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            guard let shot = try? await MKMapSnapshotter(options: options).start(),
                  let image = shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            // MapKit can snap to a slightly different zoom than asked, so measure where two points
            // landed (snapshot y points up) and work out the area the image really covers.
            let a = MKMapPoint(x: rect.midX, y: rect.midY)
            let b = MKMapPoint(x: rect.midX + rect.width / 4, y: rect.midY + rect.height / 4)
            let pa = shot.point(for: a.coordinate), pb = shot.point(for: b.coordinate)
            let sx = (pb.x - pa.x) / (b.x - a.x), sy = (pa.y - pb.y) / (b.y - a.y)
            let s = shot.image.size
            return Backdrop(image: image, rect: MKMapRect(x: a.x - pa.x / sx, y: a.y - (s.height - pa.y) / sy,
                                                          width: s.width / sx, height: s.height / sy))
        }

        /// The tiles of `overlay` covering `rect` at zoom `z`, drawn into one picture.
        private static func stitch(_ overlay: MKTileOverlay, rect: MKMapRect, z: Int) async -> Backdrop? {
            let n = 1 << z, size = 256
            let span = MKMapSize.world.width / Double(n)
            let x0 = Int((rect.minX / span).rounded(.down)), x1 = Int((rect.maxX / span).rounded(.up))
            let y0 = max(0, Int((rect.minY / span).rounded(.down))), y1 = min(n, Int((rect.maxY / span).rounded(.up)))
            guard x1 > x0, y1 > y0,
                  let ctx = CGContext(data: nil, width: (x1 - x0) * size, height: (y1 - y0) * size, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            await withTaskGroup(of: (Int, Int, CGImage?).self) { group in
                for x in x0..<x1 {
                    for y in y0..<y1 {
                        group.addTask {
                            let path = MKTileOverlayPath(x: (x % n + n) % n, y: y, z: z, contentScaleFactor: 1)
                            let data: Data? = await withCheckedContinuation { c in
                                overlay.loadTile(at: path) { data, _ in c.resume(returning: data) }
                            }
                            let image = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                            return (x, y, image)
                        }
                    }
                }
                for await (x, y, image) in group {
                    guard let image else { continue }
                    ctx.draw(image, in: CGRect(x: (x - x0) * size, y: (y1 - 1 - y) * size, width: size, height: size))
                }
            }
            guard let image = ctx.makeImage() else { return nil }
            return Backdrop(image: image, rect: MKMapRect(x: Double(x0) * span, y: Double(y0) * span,
                                                          width: Double(x1 - x0) * span, height: Double(y1 - y0) * span))
        }

        /// The whole world with the region cut out, plus any enclaves inside the region, for dimming.
        /// Drawn as vectors by MapKit, so the edge stays sharp at every zoom.
        nonisolated private static func outside(_ outline: RegionOutlines.Polygons) -> MKMultiPolygon {
            let w = MKMapRect.world
            let corners = [MKMapPoint(x: w.minX, y: w.minY), MKMapPoint(x: w.maxX, y: w.minY),
                           MKMapPoint(x: w.maxX, y: w.maxY), MKMapPoint(x: w.minX, y: w.maxY)]
            let world = MKPolygon(points: corners, count: corners.count, interiorPolygons: outline.map { polygon($0[0]) })
            return MKMultiPolygon([world] + outline.flatMap { $0.dropFirst().map(polygon) })
        }

        /// Every ring of the region as a line, leaving out edges where Natural Earth splits shapes at ±180°.
        nonisolated private static func border(_ outline: RegionOutlines.Polygons) -> MKMultiPolyline {
            var lines: [MKPolyline] = []
            var run: [GeoPoint] = []
            func flush() {
                if run.count > 1 {
                    var pts = mapPoints(run)
                    lines.append(MKPolyline(points: &pts, count: pts.count))
                }
                run = []
            }
            for ring in outline.joined() {
                for (a, b) in zip(ring, ring.dropFirst() + ring.prefix(1)) {
                    if abs(a.lon) > 179.99 && abs(b.lon) > 179.99 {
                        flush()
                    } else {
                        if run.isEmpty { run.append(a) }
                        run.append(b)
                    }
                }
                flush()
            }
            return MKMultiPolyline(lines)
        }

        /// Keeps the camera on the round's region once the fly-in has finished.
        private func applyLockIfPending() {
            guard pendingLock, let c = region, let b = c.bounds else { return }
            pendingLock = false
            if flyingToRegion == c {
                lockDistance[c] = map.camera.centerCoordinateDistance * 1.25
                flyingToRegion = nil
            }
            map.cameraBoundary = MKMapView.CameraBoundary(coordinateRegion: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (b.minLat + b.maxLat) / 2, longitude: (b.minLon + b.maxLon) / 2),
                span: MKCoordinateSpan(latitudeDelta: b.maxLat - b.minLat, longitudeDelta: b.maxLon - b.minLon)))
            if let d = lockDistance[c] {
                map.setCameraZoomRange(MKMapView.CameraZoomRange(maxCenterCoordinateDistance: d), animated: false)
            }
        }

        private func clearLocks() {
            pendingLock = false
            map.cameraBoundary = nil
            map.setCameraZoomRange(nil, animated: false)
        }

        private static func rect(_ b: RegionBounds) -> MKMapRect {
            let a = MKMapPoint(CLLocationCoordinate2D(latitude: b.maxLat, longitude: b.minLon))
            let z = MKMapPoint(CLLocationCoordinate2D(latitude: b.minLat, longitude: b.maxLon))
            return MKMapRect(x: a.x, y: a.y, width: z.x - a.x, height: z.y - a.y)
        }

        // MARK: Style

        private func apply(style: MapStyle, animated: Bool) {
            if animated, let layer = container?.layer {
                let t = CATransition()
                t.type = .fade
                t.duration = 0.8
                t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(t, forKey: "style")
            }
            // The map view's own pointOfInterestFilter is ignored once a configuration is set.
            switch style {
            case .day:
                let config = MKHybridMapConfiguration(elevationStyle: .flat)
                config.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = config
                map.appearance = NSAppearance(named: .aqua)
                map.removeOverlay(nightOverlay)
            case .night:
                let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
                config.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = config
                map.appearance = NSAppearance(named: .darkAqua)
                insert(nightOverlay)
                updateNightAlpha()
            }
        }

        private var zoomLevel: Double {
            let width = max(map.bounds.width, 1)
            return log2(MKMapSize.world.width / map.visibleMapRect.width * width / 256)
        }

        /// City lights only exist to zoom 8, so let the dark street map show through when zoomed in.
        private func updateNightAlpha() {
            guard let r = map.renderer(for: nightOverlay) else { return }
            let alpha = CGFloat(min(1, max(0.35, 1 - (zoomLevel - 9) / 4)))
            if abs(r.alpha - alpha) > 0.01 { r.alpha = alpha }
        }

        // MARK: Density

        private var densityRenderer: MKOverlayRenderer? {
            densityOverlay.flatMap { map.renderer(for: $0) }
        }

        private func setDensity(visible: Bool) {
            guard let overlay = densityOverlay else { return }
            fadeTimer?.invalidate()
            if visible {
                if !map.overlays.contains(where: { $0 === overlay }) {
                    insert(overlay)
                }
                densityRenderer?.alpha = 0
                animateDensity(to: 0.85) {}
            } else {
                animateDensity(to: 0) { [weak self] in self?.map.removeOverlay(overlay) }
            }
        }

        private func animateDensity(to target: CGFloat, completion: @escaping () -> Void) {
            let start = densityRenderer?.alpha ?? 0
            let begin = Date.now
            let duration = 0.6
            fadeTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    let t = min(1, Date.now.timeIntervalSince(begin) / duration)
                    let eased = t * t * (3 - 2 * t)
                    self.densityRenderer?.alpha = start + (target - start) * eased
                    if t >= 1 {
                        timer.invalidate()
                        completion()
                    }
                }
            }
        }

        // MARK: Shape

        private var shapeRenderer: ShapeRenderer? {
            shapeOverlay.flatMap { map.renderer(for: $0) as? ShapeRenderer }
        }

        private func setShape(_ s: [GeoPoint]?) {
            if let old = shapeOverlay { map.removeOverlay(old) }
            shapeOverlay = nil
            guard let s else { return }
            let polygon = Self.polygon(s)
            shapeOverlay = polygon
            map.addOverlay(polygon, level: .aboveLabels)
        }

        private func pulse() {
            pulseTimer?.invalidate()
            let begin = Date.now
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, let r = self.shapeRenderer else { timer.invalidate(); return }
                    let t = min(1, Date.now.timeIntervalSince(begin) / 0.9)
                    r.lineWidth = 3 + 7 * sin(t * .pi)
                    r.fillColor = Palette.shape.withAlphaComponent(0.16 + 0.22 * sin(t * .pi))
                    r.setNeedsDisplay()
                    if t >= 1 { timer.invalidate() }
                }
            }
        }

        private func fly(to s: [GeoPoint]) {
            let rect = Self.polygon(s).boundingMapRect
            let padX = min(420, map.bounds.width * 0.35)
            map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 150, left: 80, bottom: 150, right: padX),
                                  animated: true)
        }

        private func finishMove(_ delta: CGSize) {
            shapeRenderer?.alpha = 1
            guard delta != .zero, let s = shape else { return }
            let moved = s.map { g -> CGPoint in
                let p = map.convert(Self.coordinate(g), toPointTo: drawing)
                return CGPoint(x: p.x + delta.width, y: p.y + delta.height)
            }
            parent.onCommit(geo(moved))
        }

        private func screenPath() -> CGPath? {
            guard let s = shape, parent.interactive else { return nil }
            return ShapeTools.path(s.map { map.convert(Self.coordinate($0), toPointTo: drawing) }, closed: true)
        }

        /// Screen points to coordinates, with longitudes unwrapped so a shape across the
        /// antimeridian stays continuous.
        private func geo(_ pts: [CGPoint]) -> [GeoPoint] {
            var out: [GeoPoint] = []
            out.reserveCapacity(pts.count)
            var previous: Double?
            for p in pts {
                let c = map.convert(p, toCoordinateFrom: drawing)
                var lon = c.longitude
                if let prev = previous {
                    while lon - prev > 180 { lon -= 360 }
                    while lon - prev < -180 { lon += 360 }
                }
                previous = lon
                out.append(GeoPoint(lat: c.latitude, lon: lon))
            }
            let mean = out.map(\.lon).reduce(0, +) / Double(max(out.count, 1))
            let shift = mean > 180 ? -360.0 : (mean < -180 ? 360.0 : 0)
            if shift != 0 { out = out.map { GeoPoint(lat: $0.lat, lon: $0.lon + shift) } }
            return out
        }

        private static func coordinate(_ g: GeoPoint) -> CLLocationCoordinate2D {
            var lon = g.lon
            while lon > 180 { lon -= 360 }
            while lon < -180 { lon += 360 }
            return CLLocationCoordinate2D(latitude: g.lat, longitude: lon)
        }

        /// Builds map points directly so longitudes past ±180 extend beyond the world width.
        nonisolated private static func polygon(_ s: [GeoPoint]) -> MKPolygon {
            var pts = mapPoints(s)
            return MKPolygon(points: &pts, count: pts.count)
        }

        nonisolated private static func mapPoints(_ s: [GeoPoint]) -> [MKMapPoint] {
            let w = MKMapSize.world.width
            return s.map { g -> MKMapPoint in
                let lat = min(85.05, max(-85.05, g.lat))
                let y = MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: 0)).y
                return MKMapPoint(x: (g.lon + 180) / 360 * w, y: y)
            }
        }

        // MARK: Keys

        private func handleKey(_ event: NSEvent) -> NSEvent? {
            guard event.window === container?.window,
                  !(event.window?.firstResponder is NSTextView) else { return event }
            switch event.keyCode {
            case 49: // space
                if !event.isARepeat || event.type == .keyUp { parent.onSpace(event.type == .keyDown) }
                return nil
            case 53 where event.type == .keyDown: // escape
                if drawing.isBusy { drawing.cancel() } else { parent.onEscape() }
                return nil
            case 36 where event.type == .keyDown: // return
                return drawing.handleReturn() ? nil : event
            default:
                return event
            }
        }

        // MARK: Region persistence

        private var regionRestored = false

        private func restoreRegion() {
            defer { regionRestored = true }
            let v = UserDefaults.standard.array(forKey: "mapRect") as? [Double] ?? []
            if v.count == 4 {
                map.setVisibleMapRect(MKMapRect(x: v[0], y: v[1], width: v[2], height: v[3]), animated: false)
            } else {
                map.setVisibleMapRect(Self.worldRect, animated: false)
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tiles)
                if tiles === densityOverlay { r.alpha = 0 }
                return r
            }
            if overlay === regionDim, let dim = regionDim {
                let r = DimRenderer(multiPolygon: dim)
                r.fillColor = NSColor.black.withAlphaComponent(0.55)
                r.backdrop = backdrop
                return r
            }
            if overlay === regionBorder, let border = regionBorder {
                let r = MKMultiPolylineRenderer(multiPolyline: border)
                r.strokeColor = NSColor.white.withAlphaComponent(0.75)
                r.lineWidth = 1.5
                r.lineJoin = .round
                return r
            }
            if let polygon = overlay as? MKPolygon {
                let r = ShapeRenderer(polygon: polygon)
                r.fillColor = Palette.shape.withAlphaComponent(0.16)
                r.strokeColor = Palette.shape
                r.lineWidth = 3
                r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            if style == .night { updateNightAlpha() }
        }

        /// Reports once, when the map has fully drawn after its first move into place.
        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            guard fullyRendered, regionSettled, !reportedRender else { return }
            reportedRender = true
            parent.onFirstRender()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if layoutReady { regionSettled = true }
            applyLockIfPending()
            guard regionRestored else { return }
            let r = mapView.visibleMapRect
            UserDefaults.standard.set([r.origin.x, r.origin.y, r.size.width, r.size.height], forKey: "mapRect")
        }
    }
}
