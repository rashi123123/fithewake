import SwiftUI

/// The Crown Glass rings. Each time the app opens from another app, the rings
/// start nearer and facing you, then tilt back into their resting perspective.
/// Tab switches and brief interruptions (Control Center, notifications) don't replay it.
struct CrownGlassArtwork: View {
    @Environment(\.wakeAtmosphere) private var sky
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    /// The opening's clock: 0 is its first frame, 1 its last. Easing happens per ring in the drawing.
    @State private var clock = CrownIntro.frozen ?? 0
    @State private var opened = false

    var body: some View {
        // The light point follows the hour, so a once-a-minute redraw is enough.
        // Redrawing this multi-pass blur every second cost battery overnight for no visible change.
        TimelineView(.animation(minimumInterval: 60, paused: reduceMotion || phase != .active)) { time in
            CrownCanvas(clock: clock, still: reduceMotion, palette: StudyPalette(sky: sky),
                        hour: LocalDayClock.hour(at: time.date))
        }
        .mask {
            // Fade the top and bottom into the sky, and the ring ends before the screen edges.
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.07),
                                   .init(color: .white, location: 0.75), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.16),
                                             .init(color: .white, location: 0.84), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
        }
        .onAppear { if phase == .active { open() } }
        .onChange(of: phase) { _, now in
            if now == .active { open() }
            if now == .background { reset() }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func open() {
        guard !opened, CrownIntro.frozen == nil else { return }
        opened = true
        CrownIntroProbe.shared.begin(seconds: CrownIntro.duration + 0.4)
        // The clock runs linearly; each ring eases on its own curve in the drawing.
        // It starts once launch work has passed, so the first frames don't stutter.
        // Reduce Motion: a short crossfade, no movement.
        withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .linear(duration: CrownIntro.duration).delay(0.3)) { clock = 1 }
    }

    /// Back in the opening pose while away, so the next open starts from it.
    private func reset() {
        guard CrownIntro.frozen == nil else { return }
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) { clock = 0; opened = false }
    }
}

/// Re-renders the rings for every interpolated `clock` value during the opening.
private struct CrownCanvas: View, Animatable {
    var clock: Double
    let still: Bool
    let palette: StudyPalette
    let hour: Double
    var animatableData: Double {
        get { clock }
        set { clock = newValue }
    }

    var body: some View {
        // The rings fade in over the first third, so the opening never starts with a hard cut.
        let fade = still ? clock : min(1, clock / 0.32)
        Canvas { original, size in
            CrownIntroProbe.shared.canvasRenders += 1
            var context = original
            let scale = size.width / 390
            context.scaleBy(x: scale, y: scale)
            drawGlassCrown(in: &context, palette: palette, hour: hour, intro: still ? 1 : clock)
        }
        // Never fully transparent: SwiftUI skips drawing at zero opacity, which would put
        // the first, costliest render inside the move. This way it happens during the start delay.
        .opacity(max(0.002, fade * fade * (3 - 2 * fade)))
    }
}

private enum CrownIntro {
    /// Slow on purpose: a quiet, one-time settle that never blocks the controls.
    static let duration = 4.0
    /// Holds the opening at one pose for design captures.
    static let frozen: Double? = LaunchFlag.previewIntro.value.flatMap(Double.init).flatMap { (0...1).contains($0) ? $0 : nil }
}

/// Measures main-thread frame pacing and canvas renders during the opening.
/// Runs only when launched with `LaunchFlag.introProbe`.
@Observable final class CrownIntroProbe: NSObject {
    static let shared = CrownIntroProbe()
    static let enabled = LaunchFlag.introProbe.isSet
    @ObservationIgnored var canvasRenders = 0
    private(set) var summary = ""
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var started: CFTimeInterval = 0
    @ObservationIgnored private var last: CFTimeInterval = 0
    @ObservationIgnored private var seconds: CFTimeInterval = 0
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var late = 0
    @ObservationIgnored private var lateAt: [String] = []
    @ObservationIgnored private var worst: CFTimeInterval = 0

    func begin(seconds: Double) {
        guard Self.enabled, link == nil, summary.isEmpty else { return }
        self.seconds = seconds
        canvasRenders = 0; ticks = 0; late = 0; worst = 0; last = 0
        started = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 {
            let gap = link.timestamp - last
            if gap > link.duration * 1.5 { late += 1; lateAt.append("\(Int((link.timestamp - started) * 1000))") }
            worst = max(worst, gap)
        }
        last = link.timestamp
        ticks += 1
        guard link.timestamp - started >= seconds else { return }
        link.invalidate(); self.link = nil
        defer { print("INTRO PROBE: \(summary)") }
        summary = "intro \(seconds) s: \(ticks) display frames, \(late) late, worst \(Int(worst * 1000)) ms, \(canvasRenders) canvas renders; late at ms \(lateAt.joined(separator: ","))"
    }
}

private struct StudyPalette {
    let light: Color
    let core: Color
    let deep: Color
    let body: Color
    init(sky: DayAtmosphere) {
        light = sky.ring.color
        core = sky.ring.mixed(with: SkyRGB(0xFFFFFF), amount: 0.73).color
        deep = sky.top.color
        body = sky.middle.color
    }
}

private let studyBounds = Path(CGRect(x: -120, y: -160, width: 630, height: 640))

private func atmosphere(_ context: inout GraphicsContext, at point: CGPoint, color: Color, radius: CGFloat, strength: Double) {
    context.fill(studyBounds, with: .radialGradient(Gradient(stops: [
        .init(color: color.opacity(strength), location: 0),
        .init(color: color.opacity(strength * 0.27), location: 0.42),
        .init(color: .clear, location: 1)
    ]), center: point, startRadius: 0, endRadius: radius))
}

private func opticalRibbon(_ points: [CGPoint], width: CGFloat, scales: [CGFloat]? = nil) -> Path {
    guard points.count > 2 else { return Path() }
    var path = Path()
    for side in [1.0, -1.0] {
        for j in 0..<points.count {
            let i = side > 0 ? j : points.count - 1 - j
            let p = points[i]
            let before = points[max(0, i-1)], after = points[min(points.count-1, i+1)]
            let dx = after.x-before.x, dy = after.y-before.y
            let length = max(0.001, hypot(dx, dy))
            let t = Double(i) / Double(points.count-1)
            let half = width / 2 * (scales?[i] ?? 1) * pow(max(0, sin(.pi*t)), 1.2)
            let edge = CGPoint(x: p.x - dy/length*half*side, y: p.y + dx/length*half*side)
            if side > 0 && j == 0 { path.move(to: edge) } else { path.addLine(to: edge) }
        }
    }
    path.closeSubpath()
    return path
}

private func trace(_ points: [CGPoint]) -> Path {
    Path { path in
        for (i,p) in points.enumerated() { if i == 0 { path.move(to: p) } else { path.addLine(to: p) } }
    }
}

private func lightPoint(_ context: inout GraphicsContext, at center: CGPoint, palette: StudyPalette, radius: CGFloat) {
    atmosphere(&context, at: center, color: palette.light, radius: 42, strength: 0.75)
    context.drawLayer { layer in
        layer.addFilter(.blur(radius: 3))
        layer.fill(Path(ellipseIn: CGRect(x: center.x-radius*1.8, y: center.y-radius*1.8, width: radius*3.6, height: radius*3.6)),
                   with: .color(palette.core))
    }
    context.fill(Path(ellipseIn: CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2)), with: .color(.white))
}

/// Masks for the four blur levels: sharp at the crest, progressively softer toward the sides.
private let focusBands: [Gradient] = (0..<4).map { level in
    Gradient(stops: (0...48).map { sample in
        let position = Double(sample) / 48
        let x = -120 + 630 * position
        let progress = min(3, max(0, (abs(x - 195) - 55) / 55))
        let weight = max(0, 1 - abs(progress - Double(level)))
        return .init(color: .white.opacity(weight), location: position)
    })
}

/// Gentle start, most of the move early, then a long soft landing.
/// Cubic Bézier (0.3, 0, 0.1, 1), solved for x by bisection.
private func settleCurve(_ x: Double) -> Double {
    let x = min(1, max(0, x))
    func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
        3*a*s*(1-s)*(1-s) + 3*b*s*s*(1-s) + s*s*s
    }
    var low = 0.0, high = 1.0
    for _ in 0..<22 {
        let mid = (low + high) / 2
        if bezier(mid, 0.3, 0.1) < x { low = mid } else { high = mid }
    }
    return bezier((low + high) / 2, 0, 1)
}

/// `intro` is the opening's clock, 0...1. Each ring starts nearer and 21° more
/// upright, then tilts back; the inner ring settles first and the outer ones follow.
private func drawGlassCrown(in context: inout GraphicsContext, palette p: StudyPalette, hour: Double, intro: Double) {
    let center = CGPoint(x: 195, y: 178)
    let focalLength: CGFloat = 900
    // Rotate the circle's plane around its horizontal axis, then project it.
    // The far side and ring spacing recede together without any sideways roll.
    func project(radius: CGFloat, angle: Double, settle: Double) -> (point: CGPoint, scale: CGFloat) {
        let tilt = (57 - 21 * (1 - settle)) * Double.pi / 180
        let dolly = -120 * CGFloat(1 - settle)
        let distance = radius * sin(angle)
        let depth = distance * sin(tilt)
        let perspective = focalLength / (focalLength + depth + dolly)
        return (CGPoint(x: center.x + radius * cos(angle) * perspective,
                        y: center.y - distance * cos(tilt) * perspective), perspective)
    }
    let lit: CGFloat = 214
    let delays = [0.14, 0.07, 0.0]
    let rims = [CGFloat(262), lit, CGFloat(166)].enumerated().map { index, radius in
        let settle = settleCurve((intro - delays[index]) / (1 - delays[0]))
        let samples = (0...200).map { i in project(radius: radius, angle: Double(i)/200 * .pi, settle: settle) }
        let reflection = (0...200).map { i in project(radius: radius - 5, angle: Double(i)/200 * .pi, settle: settle).point }
        // Line width follows the projection, so each far crest is finer than its sides.
        // The nearest ring is the brightest; the outer ones recede.
        let points = samples.map(\.point), scales = samples.map(\.scale)
        let width = CGFloat(4.6 - Double(index) * 0.35)
        // Paths are built once per frame and shared by every blur band below.
        return (points: points, reflection: trace(reflection),
                core: opticalRibbon(points, width: width, scales: scales),
                fine: opticalRibbon(points, width: width * 0.3, scales: scales),
                crest: project(radius: radius, angle: .pi / 2, settle: settle).point, settle: settle,
                strength: [0.82, 0.92, 1.0][index])
    }
    atmosphere(&context, at: CGPoint(x: 195, y: 110), color: p.light, radius: 230, strength: 0.19)
    for rim in rims {
        var surface = trace(rim.points)
        surface.addLine(to: CGPoint(x: -160, y: 370)); surface.addLine(to: CGPoint(x: 550, y: 370)); surface.closeSubpath()
        context.fill(surface, with: .linearGradient(Gradient(stops: [
            .init(color: p.light.opacity(0.095), location: 0),
            .init(color: p.light.opacity(0.045), location: 0.35),
            .init(color: .clear, location: 1)
        ]), startPoint: rim.crest, endPoint: CGPoint(x: 195, y: 220)))
    }
    // Broad bloom stays continuous; the optical edges below receive spatial blur.
    // It is kept low so the dark gaps between the rings stay visible.
    for (width, blur, alpha) in [(CGFloat(38), 24.0, 0.40), (CGFloat(18), 9.0, 0.43)] {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: blur))
            for rim in rims {
                layer.fill(opticalRibbon(rim.points, width: width), with: .color(p.light.opacity(alpha * rim.strength)))
            }
        }
    }
    // Crossfade four fixed blur levels with overlapping, symmetric masks.
    // This softens the rim itself progressively, rather than hiding a sharp edge.
    // All three rings share each filter pass; blur does not animate with the light point.
    context.drawLayer { highlights in
        highlights.blendMode = .plusLighter
        for (level, blur) in [0.65, 2.5, 6.5, 12.0].enumerated() {
            highlights.drawLayer { band in
                band.blendMode = .normal
                band.drawLayer { optical in
                    optical.addFilter(.blur(radius: blur))
                    for rim in rims {
                        optical.fill(rim.core, with: .color(p.core.opacity(0.95 * rim.strength)))
                        optical.fill(rim.fine, with: .color(p.core.opacity(0.75 * rim.strength)))
                        optical.stroke(rim.reflection, with: .linearGradient(
                            Gradient(colors: [p.core.opacity(0.32), p.light.opacity(0.04)]),
                            startPoint: rim.crest, endPoint: center), lineWidth: 0.7)
                    }
                }
                band.blendMode = .destinationIn
                band.fill(studyBounds, with: .linearGradient(focusBands[level],
                    startPoint: CGPoint(x: -120, y: 0), endPoint: CGPoint(x: 510, y: 0)))
            }
        }
    }
    // During the opening the light point fades in late and glides along its ring into place.
    let arrival = settleCurve((intro - 0.18) / 0.82)
    let shine = min(1, max(0, (intro - 0.22) / 0.4))
    let angle = 1.4 + 0.12*sin(hour * .pi/12) + 0.55 * (1 - arrival)
    var light = context
    light.opacity *= shine * shine * (3 - 2 * shine)
    // The rim catches the light on both sides of the point, fading along the ring,
    // so the point reads as light on the glass rather than a dot placed on top.
    let glint = (0...60).map { i in project(radius: lit, angle: angle - 0.32 + 0.64 * Double(i)/60, settle: rims[1].settle).point }
    for (width, blur, color) in [(CGFloat(14), 6.0, p.light.opacity(0.7)), (CGFloat(3), 1.2, Color.white.opacity(0.85))] {
        light.drawLayer { layer in
            layer.addFilter(.blur(radius: blur))
            layer.fill(opticalRibbon(glint, width: width), with: .color(color))
        }
    }
    lightPoint(&light, at: project(radius: lit, angle: angle, settle: rims[1].settle).point, palette: p, radius: 2.8)
}
