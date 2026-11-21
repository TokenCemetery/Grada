import Foundation

/// Weight in the user's units, and body mass index with the WHO's adult classes (#132).
nonisolated enum BodyMass {
    static let poundsPerKilogram = 2.204_622_6
    /// The WHO's normal range for adults (WHO 2000, Technical Report Series 894), 18.5–24.9: every BMI that shows as one
    /// of those at one decimal, the same values `BMIClass` calls normal.
    static let normalBMI = 18.45...24.95

    enum BMIClass: CaseIterable {
        case underweight, normal, preObese, obese

        /// WHO 2000: underweight below 18.5, normal 18.5–24.9, pre-obese 25–29.9, obese from 30. Classed at the one
        /// decimal BMI is shown with, so "25.0" never reads as Normal.
        init(_ bmi: Double) {
            self = switch (bmi * 10).rounded() / 10 {
            case ..<18.5: .underweight
            case ..<25: .normal
            case ..<30: .preObese
            default: .obese
            }
        }

        var title: String {
            switch self {
            case .underweight: String(localized: "Underweight", comment: "WHO BMI class")
            case .normal: String(localized: "Normal", comment: "WHO BMI class")
            case .preObese: String(localized: "Pre-obese", comment: "WHO BMI class")
            case .obese: String(localized: "Obese", comment: "WHO BMI class")
            }
        }
    }

    /// Kilograms, or pounds in the US.
    static func unit(usesMetric: Bool) -> String {
        usesMetric ? String(localized: "kg", comment: "Unit: kilograms") : String(localized: "lb", comment: "Unit: pounds")
    }

    static func display(_ kilograms: Double, usesMetric: Bool) -> Double {
        usesMetric ? kilograms : kilograms * poundsPerKilogram
    }

    /// Weight in kilograms divided by height in metres squared.
    static func bmi(kilograms: Double, centimeters: Double) -> Double {
        let meters = centimeters / 100
        return kilograms / (meters * meters)
    }
}
