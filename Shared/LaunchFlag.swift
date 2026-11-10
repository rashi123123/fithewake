import Foundation

/// Launch arguments that put a Debug build into a repeatable state for UI tests
/// and design captures. Compiled into the app and the UI tests, so both spell
/// them the same way. Release builds ignore them.
enum LaunchFlag: String {
    case keepAwake = "qa-keep-awake"
    case largeType = "qa-large-type"
    case onboarding = "qa-onboarding"
    case skipOnboarding = "qa-skip-onboarding"
    case introProbe = "qa-intro-probe"
    /// Silences the heart-rate stream once, to exercise the real recovery path.
    case silentStreamOnce = "qa-silent-stream-once"
    /// `=<0..<24>`: draw the sky at this local hour.
    case previewHour = "preview-hour"
    /// `=<0...1>`: hold the opening animation at this pose.
    case previewIntro = "preview-intro"

    var argument: String { "--" + rawValue }
    func argument(_ value: Any) -> String { "\(argument)=\(value)" }

    var isSet: Bool { Self.honored && ProcessInfo.processInfo.arguments.contains(argument) }
    var value: String? {
        guard Self.honored else { return nil }
        let prefix = argument + "="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private static var honored: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
