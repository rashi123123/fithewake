import SwiftUI

extension URL {
    static let appSettings = URL(string: UIApplication.openSettingsURLString)!
}

extension View {
    /// The translucent rounded card that groups content on the night sky.
    func wakeCard() -> some View { modifier(WakeCard()) }
}

private struct WakeCard: ViewModifier {
    @Environment(\.wakeAtmosphere) private var sky
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background(reduceTransparency ? AnyShapeStyle(sky.surface.color) : AnyShapeStyle(sky.highlight.color.opacity(0.055)),
                           in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

struct CardDivider: View {
    @Environment(\.wakeAtmosphere) private var sky
    var body: some View { Divider().overlay(sky.highlight.color.opacity(0.05)) }
}

/// A symbol or step number beside a title and a detail line.
struct InfoRow: View {
    enum Marker { case symbol(String), number(Int) }
    @Environment(\.wakeAtmosphere) private var sky
    let marker: Marker
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                switch marker {
                case .symbol(let name):
                    Image(systemName: name).font(.body).padding(.top, 1)
                case .number(let number):
                    Text("\(number)")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(sky.action.color.opacity(0.14)))
                }
            }
            .foregroundStyle(sky.action.color)
            .frame(width: 26)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(sky.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }
    private var accessibilityText: String {
        if case .number(let number) = marker { return "Step \(number): \(title). \(detail)" }
        return "\(title). \(detail)"
    }
}

struct SetupStep: Hashable {
    let symbol: String
    let title: String
    let detail: String
}

/// The latest reading in the compact style used on cards.
struct BPMReadout: View {
    @Environment(\.wakeAtmosphere) private var sky
    let bpm: Int?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(bpm.map(String.init) ?? "—")
                .font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
            Text("bpm").font(.system(.caption, design: .rounded).weight(.medium)).foregroundStyle(sky.secondary.color)
        }
        .contentTransition(.numericText())
        .animation(.snappy, value: bpm)
    }
}

/// Identical centered SF silhouettes keep the translucent rim touching the
/// heart throughout contraction, without a separate outline or empty gap.
struct ReceivingHeart: View {
    @Environment(\.wakeAtmosphere) private var sky
    let receiving: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if receiving && !reduceMotion && scenePhase == .active {
            PhaseAnimator([false, true]) { contracted in
                symbol(contracted: contracted)
            } animation: { contracted in
                .easeInOut(duration: contracted ? 1.0 : 1.3)
            }
        } else {
            symbol(contracted: false)
        }
    }

    private func symbol(contracted: Bool) -> some View {
        ZStack {
            Image(systemName: "heart.fill")
                .font(.body.weight(.regular))
                .opacity(contracted ? 0.24 : 0)
            Image(systemName: "heart.fill")
                .font(.body.weight(.regular))
                .scaleEffect(contracted ? 0.86 : 1)
        }
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(receiving ? sky.action.color : Color.orange)
    }
}
