import Foundation

/// Cuff readings' categories from the 2017 ACC/AHA guideline (Whelton et al., Hypertension 2018;71:e13): normal
/// below 120/80, elevated 120–129 with diastolic below 80, stage 1 hypertension 130–139 or 80–89, stage 2 from 140 or
/// 90. When the two numbers fall in different categories, the higher one counts. The guideline bases a diagnosis on
/// the average of several readings on several occasions, so a category here describes readings, not a diagnosis (#135).
nonisolated enum BloodPressure {
    enum Category: Int, CaseIterable, Comparable {
        case normal, elevated, stage1, stage2

        init(systolic: Double, diastolic: Double) {
            // Readings are whole millimetres of mercury; a day's average is classed as it's shown, rounded.
            let systolic = systolic.rounded(), diastolic = diastolic.rounded()
            let bySystolic: Category = switch systolic {
            case ..<120: .normal
            case ..<130: .elevated
            case ..<140: .stage1
            default: .stage2
            }
            let byDiastolic: Category = switch diastolic {
            case ..<80: .normal
            case ..<90: .stage1
            default: .stage2
            }
            self = max(bySystolic, byDiastolic)
        }

        static func < (lhs: Category, rhs: Category) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .normal: String(localized: "Normal", comment: "ACC/AHA blood pressure category")
            case .elevated: String(localized: "Elevated", comment: "ACC/AHA blood pressure category")
            case .stage1: String(localized: "Stage 1", comment: "ACC/AHA blood pressure category: stage 1 hypertension")
            case .stage2: String(localized: "Stage 2", comment: "ACC/AHA blood pressure category: stage 2 hypertension")
            }
        }

        var rating: DayRating {
            switch self {
            case .normal: .good
            case .elevated, .stage1: .fair
            case .stage2: .poor
            }
        }
    }

    static let unit = "mmHg"
    /// Days a reading stays colored on the card; an older one is shown plain, with its date. Grada's choice.
    static let freshDays = 7

    /// "122/78", as a cuff shows it.
    static func reading(systolic: Double, diastolic: Double) -> String {
        let whole = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
        return "\(systolic.formatted(whole))/\(diastolic.formatted(whole))"
    }

    /// Days with both numbers, oldest first.
    static func readings(systolic: [DayValue], diastolic: [DayValue]) -> [(day: Date, systolic: Double, diastolic: Double)] {
        let diastolicByDay = Dictionary(diastolic.compactMap { day in day.value.map { (day.day, $0) } }) { first, _ in first }
        return systolic.compactMap { day in
            guard let value = day.value, let other = diastolicByDay[day.day] else { return nil }
            return (day.day, value, other)
        }
    }
}
