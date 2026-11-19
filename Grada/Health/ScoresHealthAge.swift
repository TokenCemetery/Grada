import Foundation

/// Health age: the user's age plus, for each input, the years of aging that carry the same all-cause mortality
/// risk. Each input's risk ratio comes from a meta-analysis or pooled cohort, against a published reference for
/// the user's age and sex, and turns into years through the Gompertz law: adult mortality doubles about every
/// 8 years (Finch et al. 1990), so years = 8 × log₂(risk ratio). The studies adjusted for different things and the
/// inputs overlap (fit people also walk more), so the sum somewhat overstates the total.
nonisolated enum HealthAge {
    struct Input {
        var age: Int
        /// Needed for the VO₂ max and resting heart rate norms; without it those two are left out.
        var sex: BiologicalSex? = nil
        var sleepHours: Double?
        var dailySteps: Double?
        var restingHeartRate: Double?
        var vo2Max: Double?
        /// Apple exercise minutes: moderate effort or more.
        var exerciseMinutesPerWeek: Double?
    }

    struct Impact: Equatable {
        let name: String
        /// Positive adds years, negative takes them away.
        let years: Double
    }

    /// Fewer inputs than this and the age would rest on too little.
    static let minimumInputs = 3
    /// Each input is averaged over the last 30 days.
    static let windowDays = 30
    /// Gompertz mortality doubling time for adults (Finch et al. 1990).
    static let mortalityDoublingYears = 8.0

    /// Years of aging with the same change in mortality risk.
    static func years(riskRatio: Double) -> Double {
        mortalityDoublingYears * log2(riskRatio)
    }

    static func impacts(_ input: Input) -> [Impact] {
        var impacts: [Impact] = []
        if let vo2 = input.vo2Max, let sex = input.sex {
            // Kodama et al. 2009 (JAMA 301:2024): RR 0.87 per 1 MET (3.5 ml/kg·min) higher fitness.
            let mets = (vo2 - expectedVO2Max(age: input.age, sex: sex)) / 3.5
            impacts.append(Impact(name: String(localized: "VO₂ Max"), years: mets * years(riskRatio: 0.87)))
        }
        if let rhr = input.restingHeartRate, let sex = input.sex {
            // Zhang et al. 2016 (CMAJ 188:E53): RR 1.09 per 10 bpm higher.
            let tens = (rhr - expectedRestingHeartRate(age: input.age, sex: sex)) / 10
            impacts.append(Impact(name: String(localized: "Resting HR"), years: tens * years(riskRatio: 1.09)))
        }
        if let steps = input.dailySteps {
            let reference = input.age < 60 ? 7_803.0 : 5_649.0
            impacts.append(Impact(name: String(localized: "Steps"), years: years(riskRatio: stepsRisk(steps) / stepsRisk(reference))))
        }
        if let hours = input.sleepHours {
            impacts.append(Impact(name: String(localized: "Sleep"), years: years(riskRatio: sleepRisk(hours))))
        }
        if let minutes = input.exerciseMinutesPerWeek {
            impacts.append(Impact(name: String(localized: "Exercise"), years: years(riskRatio: exerciseRisk(minutes))))
        }
        return impacts
    }

    static func age(_ input: Input) -> Double? {
        let impacts = impacts(input)
        guard impacts.count >= minimumInputs else { return nil }
        return Double(input.age) + impacts.reduce(0) { $0 + $1.years }
    }

    /// Median measured VO₂ max (ml/kg·min) for the age and sex: the 50th percentiles of the FRIEND registry's
    /// treadmill tests (Kaminsky et al. 2015, Mayo Clin Proc 90:1515, Table 3). Under 20 uses the 20s,
    /// 80 and over the 70s.
    static func expectedVO2Max(age: Int, sex: BiologicalSex) -> Double {
        VO2MaxZones.bounds(age: age, sex: sex)[1]
    }

    /// Median resting pulse for the age and sex in NHANES 1999–2008 (Ostchega et al. 2011, NHSR 41, Tables 2 and 3):
    /// ages 20–39, 40–59, 60–79 and 80+. That pulse was taken seated after 4 minutes' rest; Apple's resting heart
    /// rate is usually a little lower, which errs toward a younger health age.
    static func expectedRestingHeartRate(age: Int, sex: BiologicalSex) -> Double {
        let row = min(max(age / 20 - 1, 0), 3)
        return sex == .male ? [69.0, 68, 67, 68][row] : [74.0, 71, 70, 71][row]
    }

    /// Mortality risk against the lowest quartile, from Paluch et al. 2022 (Lancet Public Health 7:e219): quartile
    /// medians of 3553, 5801, 7842 and 10 901 steps had HRs of 1, 0.60, 0.55 and 0.47. Between medians the
    /// log-risk is interpolated; beyond them it stays flat. References are the median of the cohorts' median steps
    /// for under-60s (7803) and 60 and over (5649), as reported in the paper.
    static func stepsRisk(_ steps: Double) -> Double {
        let points: [(steps: Double, risk: Double)] = [(3_553, 1), (5_801, 0.60), (7_842, 0.55), (10_901, 0.47)]
        guard steps > points[0].steps else { return points[0].risk }
        guard let upper = points.firstIndex(where: { $0.steps >= steps }) else { return points[points.count - 1].risk }
        let (low, high) = (points[upper - 1], points[upper])
        let share = (steps - low.steps) / (high.steps - low.steps)
        return exp(log(low.risk) + share * (log(high.risk) - log(low.risk)))
    }

    /// Cappuccio et al. 2010 (Sleep 33:585): RR 1.12 for short and 1.30 for long sleep against the studies'
    /// reference, mostly 7 or 7–8 hours. The pooled studies drew the lines differently (short from ≤4 to <7 hours,
    /// long from >8 to ≥12), so under 7 and over 8 hours is the nearest single reading of their reference.
    static func sleepRisk(_ hours: Double) -> Double {
        if hours < 7 { return 1.12 }
        return hours > 8 ? 1.30 : 1
    }

    /// Arem et al. 2015 (JAMA Intern Med 175:959), as multiples of the 150-minute guideline against none:
    /// below it HR 0.80, 1–2× 0.69, 2–3× 0.63, 3–5× 0.61, 5–10× 0.61, 10× and up
    /// 0.69 (0.68 in the author manuscript). Returned against the guideline (1–2×), so meeting it adds nothing. Exercise minutes stand in for the study's moderate-intensity minutes.
    static func exerciseRisk(_ minutesPerWeek: Double) -> Double {
        let multiple = minutesPerWeek / 150
        let risk = switch multiple {
        case ..<0.001: 1.0
        case ..<1: 0.80
        case ..<2: 0.69
        case ..<3: 0.63
        case ..<10: 0.61
        default: 0.69
        }
        return risk / 0.69
    }
}
