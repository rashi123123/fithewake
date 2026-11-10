import SwiftUI

/// Local wall-clock hour, independent of the scheduled alarm.
/// Fixed local-time anchors are intentional; no location or sunrise service is used.
enum LocalDayClock {
    static let previewHour: Double? = LaunchFlag.previewHour.value
        .flatMap(Double.init).flatMap { $0.isFinite && (0..<24).contains($0) ? $0 : nil }

    static func hour(at date: Date) -> Double {
        if let previewHour { return previewHour }
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0)/60
            + Double(parts.second ?? 0)/3600 + Double(parts.nanosecond ?? 0)/3_600_000_000_000
    }

    static func greeting(at date: Date) -> String {
        switch hour(at: date) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        case 18..<22: "Good evening"
        default: "Good night"
        }
    }
}

struct SkyRGB: Equatable {
    let r: Double, g: Double, b: Double
    init(_ hex: Int) {
        r = Double((hex >> 16) & 255)/255
        g = Double((hex >> 8) & 255)/255
        b = Double(hex & 255)/255
    }
    private init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    var color: Color { Color(red: r, green: g, blue: b) }
    func mixed(with other: SkyRGB, amount: Double) -> SkyRGB {
        SkyRGB(r: r + (other.r-r)*amount, g: g + (other.g-g)*amount, b: b + (other.b-b)*amount)
    }
}

/// The app's colors for the current local hour: the sky from top to bottom, plus accents.
struct DayAtmosphere: Equatable {
    let top: SkyRGB
    let upper: SkyRGB
    let middle: SkyRGB
    let lower: SkyRGB
    let bottom: SkyRGB
    let glow: SkyRGB
    let stars: Double
    let action: SkyRGB
    let highlight: SkyRGB
    let ring: SkyRGB
    var secondary: SkyRGB { upper.mixed(with: SkyRGB(0xBFBBC5), amount: 0.84) }
    var surface: SkyRGB { middle.mixed(with: SkyRGB(0x18181B), amount: 0.90) }

    private static let night = DayAtmosphere(
        top: SkyRGB(0x1F0A3D), upper: SkyRGB(0x360857), middle: SkyRGB(0x2B0642), lower: SkyRGB(0x1C092D), bottom: SkyRGB(0x0B0613),
        glow: SkyRGB(0xA61FF2), stars: 1, action: SkyRGB(0xFF3882), highlight: SkyRGB(0xDB82FF), ring: SkyRGB(0xC275FF))
    private static let dawn = DayAtmosphere(
        top: SkyRGB(0x261138), upper: SkyRGB(0x4A1A52), middle: SkyRGB(0x3D143F), lower: SkyRGB(0x28132E), bottom: SkyRGB(0x100918),
        glow: SkyRGB(0xD974C1), stars: 0.6, action: SkyRGB(0xD8679B), highlight: SkyRGB(0xEDB7D8), ring: SkyRGB(0xE6A4D0))
    private static let day = DayAtmosphere(
        top: SkyRGB(0x0C1530), upper: SkyRGB(0x182E57), middle: SkyRGB(0x181F47), lower: SkyRGB(0x11152D), bottom: SkyRGB(0x080C16),
        glow: SkyRGB(0x777DDF), stars: 0.18, action: SkyRGB(0x8F7BE6), highlight: SkyRGB(0xB3BFFF), ring: SkyRGB(0x9EAFFF))
    private static let dusk = DayAtmosphere(
        top: SkyRGB(0x2B0E30), upper: SkyRGB(0x571A38), middle: SkyRGB(0x401133), lower: SkyRGB(0x2A102A), bottom: SkyRGB(0x110815),
        glow: SkyRGB(0xD879A4), stars: 0.55, action: SkyRGB(0xDC755F), highlight: SkyRGB(0xEFB1AD), ring: SkyRGB(0xDB9AAF))
    private static let anchors: [(hour: Double, palette: DayAtmosphere)] = [
        (0, night), (4, night), (6.5, dawn), (10, day), (15, day),
        (18.5, dusk), (21.5, night), (24, night)
    ]

    static func at(_ date: Date) -> DayAtmosphere {
        let hour = LocalDayClock.hour(at: date)
        for (a, b) in zip(anchors, anchors.dropFirst()) where hour >= a.hour && hour <= b.hour {
            let fraction = (hour-a.hour)/(b.hour-a.hour)
            return a.palette.mixed(with: b.palette, amount: fraction*fraction*(3-2*fraction))
        }
        return night
    }

    private func mixed(with other: DayAtmosphere, amount t: Double) -> DayAtmosphere {
        DayAtmosphere(
            top: top.mixed(with: other.top, amount: t), upper: upper.mixed(with: other.upper, amount: t),
            middle: middle.mixed(with: other.middle, amount: t), lower: lower.mixed(with: other.lower, amount: t),
            bottom: bottom.mixed(with: other.bottom, amount: t), glow: glow.mixed(with: other.glow, amount: t),
            stars: stars + (other.stars-stars)*t, action: action.mixed(with: other.action, amount: t),
            highlight: highlight.mixed(with: other.highlight, amount: t), ring: ring.mixed(with: other.ring, amount: t))
    }
}

private struct WakeAtmosphereKey: EnvironmentKey {
    static let defaultValue = DayAtmosphere.at(.now)
}

extension EnvironmentValues {
    var wakeAtmosphere: DayAtmosphere {
        get { self[WakeAtmosphereKey.self] }
        set { self[WakeAtmosphereKey.self] = newValue }
    }
}

/// The night sky behind the main screens, with slowly twinkling stars.
struct NightBackground: View {
    @Environment(\.wakeAtmosphere) private var sky
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [sky.top.color, sky.lower.color, sky.bottom.color],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [sky.glow.color.opacity(0.16), .clear],
                               center: UnitPoint(x: 0.75, y: 0.28), startRadius: 0, endRadius: geometry.size.width * 0.95)
                LinearGradient(colors: [.black.opacity(0.52), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170).frame(maxHeight: .infinity, alignment: .top)
                TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduceMotion || phase != .active)) { time in
                    Canvas { context, size in
                        for index in 0..<19 {
                            let x = CGFloat((index * 157 + 41) % 997) / 997 * size.width
                            let y = CGFloat((index * 233 + 109) % 991) / 991 * size.height * 0.6
                            let wave = reduceMotion ? 0.6 : (sin(time.date.timeIntervalSinceReferenceDate / (3.8 + Double(index % 4)) + Double(index)) + 1) / 2
                            let alpha = (0.06 + wave * 0.22) * sky.stars
                            let diameter: CGFloat = index % 7 == 0 ? 1.8 : 1
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                                         with: .color(sky.highlight.color.opacity(alpha)))
                        }
                    }
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The quieter background behind forms and lists.
struct DetailBackground: View {
    @Environment(\.wakeAtmosphere) private var sky
    var body: some View {
        ZStack {
            LinearGradient(colors: [sky.lower.color, sky.bottom.color], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [sky.glow.color.opacity(0.20), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 440)
        }.ignoresSafeArea()
    }
}
