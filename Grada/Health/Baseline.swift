import Foundation

/// Personal normal range for a vital, built from the user's own recent history.
enum Baseline {
    /// Fewer days than this and the metric shows "Calibrating".
    static let minimumDays = 7

    /// Mean ± 2 SD of the history, never narrower than `minimumHalfWidth` either side,
    /// so a very stable history doesn't flag tiny changes. Nil while calibrating.
    static func normalRange(history: [Double], minimumHalfWidth: Double) -> ClosedRange<Double>? {
        guard history.count >= minimumDays else { return nil }
        let mean = history.reduce(0, +) / Double(history.count)
        let variance = history.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(history.count - 1)
        let halfWidth = max(2 * variance.squareRoot(), minimumHalfWidth)
        return (mean - halfWidth)...(mean + halfWidth)
    }

    static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
