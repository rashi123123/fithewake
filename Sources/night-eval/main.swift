import NightLab
import FitheWakeCore

// Prints the Smart Wake evaluation table in docs/SMART_WAKE_RESEARCH.md.
// Run: swift run -c release night-eval
for (smoothing, separation, arousals) in [(1, 1.0, 6.0), (5, 1.0, 6.0), (5, 0.5, 6.0), (5, 0.25, 6.0), (5, 1.0, 0.0)] {
    for early in [false, true] {
        let c = Conditions(smoothing: smoothing, arousals: arousals, separation: separation, seedOffset: 5000)
        let summary = EvaluationBench.summarize(early: early, c)
        print("\(NightEngine.version) \(early ? "early  " : "morning") smooth \(smoothing) sep \(separation) arousal \(arousals): \(summary)")
    }
}
